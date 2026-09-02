extends SimTest
## **99-PA PA-25 / A91-D-80 — the five events that could not happen**, and
## **99-PA PA-89 — the severity the Director never bought.**
##
## PA-25's defect had three independent halves, any one of which was fatal:
##
##   1. `DisasterDirector.target_provider` was declared, read in two places and
##      **never assigned**, so `_choose_target` returned `{}` for every pick;
##   2. four of the eight catalog ids are not doc 06 types at all — a
##      `traffic_pileup` is a `traffic_accident`, a `transformer_explosion` a
##      `transformer_failure` — and `DirectorIncidentSink` refuses an unknown
##      type;
##   3. the sink resolved a reference against `sim.buildings` and `sim.grid`
##      only, so a water segment or a road intersection could never resolve.
##
## Each dead pick still debited `tp_pool`, armed F3's per-type cooldown and, in
## catch-up, burned the one offline-hazard slot. Only the three weather
## injections did anything at all.
##
## PA-89's is smaller and the same shape: `severity.buy_max_cost_mult` and
## `buy_max_severity` are authored in `data/director.json` and had zero readers.

const DIRECTOR_DATA := "res://data/director.json"


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


func _director(seed_value: int = 1337) -> DisasterDirector:
	var director := DisasterDirector.new(
			DirectorTables.load_from_file(DIRECTOR_DATA), RngStreams.new(seed_value))
	var weather := WeatherSystem.new(
			WeatherTables.load_from_file("res://data/weather.json"),
			RngStreams.new(seed_value))
	weather.set_city_bounds(Vector2(96, 96), 96.0)
	weather.bootstrap(_ctx(0))
	director.attach(weather, IncidentRequestSink.Recording.new())
	director.set_difficulty("standard")
	return director


func _inputs() -> DirectorInputs:
	return DirectorInputs.make({
		"city_age_days": 40, "population": 45000, "pop_peak_7d": 45000,
		"treasury": 620000, "daily_opex": 85000,
		"grid_redundancy": 0.62, "water_redundancy": 0.62, "road_redundancy": 0.62,
		"units_owned": {"fire": 4, "police": 4, "utility": 3, "water": 1,
				"construction": 2},
		"total_response_units": 14, "city_stability": 0.68, "difficulty": "standard",
	})


# ------------------------------------------------------------------- PA-25

func test_every_incident_event_names_a_type_doc_06_actually_has() -> void:
	var tables := DirectorTables.load_from_file(DIRECTOR_DATA)
	var catalog := IncidentCatalog.load_from_files()
	assert_true(catalog.is_valid(), "the incident catalog loaded")
	var mapped := 0
	for event in tables.events:
		var row: Dictionary = event
		var kind: Dictionary = tables.incident_kind(String(row["id"]))
		if kind.is_empty():
			# The three weather rows, whose whole effect is their segment.
			assert_true(String(row["id"]) in ["storm_minor", "heat_wave",
					"severe_thunderstorm"],
					"`%s` has no incident half and is not a weather row" % row["id"])
			continue
		mapped += 1
		assert_true(catalog.has_type(String(kind["type"])),
				("`%s` requests incident type `%s`, which doc 06 does not have — "
						+ "the sink refuses it and the pick dies having spent its TP")
						% [row["id"], kind["type"]])
		assert_true(String(kind.get("source", "")) != "",
				"`%s` names no §2.6.5 candidate source" % row["id"])
	assert_eq(mapped, 5, "five of the eight rows have an incident half")


func test_the_provider_is_bound_and_answers_for_every_mapped_event() -> void:
	var sim := CitySim.boot_from_files(4242)
	assert_true(sim.director.target_provider.is_valid(),
			"§2.6.3 step 8's provider is injected at boot")
	var tables := sim.director.tables
	for event in tables.events:
		var id := String((event as Dictionary)["id"])
		if tables.incident_kind(id).is_empty():
			continue
		var roster: Array = sim.director_targets(id)
		assert_true(roster.size() > 0,
				"`%s` has no legal target in the starter city" % id)
		for entry in roster:
			var row: Dictionary = entry
			for key in ["ref", "domain", "condition", "district_id",
					"base_type_weight", "exposure_factor"]:
				assert_true(row.has(key),
						"`%s` roster row is missing §2.6.5's `%s`" % [id, key])
			assert_true(float(row["base_type_weight"]) > 0.0,
					"a zero-weight row can never be picked and should not be offered")
	sim.dispose()


func test_each_mapped_event_produces_a_real_incident_attributed_to_it() -> void:
	# The end-to-end claim: force one of each, and doc 06 has an incident with
	# this event's uid on it. On the fork four of the five became nothing.
	var tables := DirectorTables.load_from_file(DIRECTOR_DATA)
	for event in tables.events:
		var id := String((event as Dictionary)["id"])
		if tables.incident_kind(id).is_empty():
			continue
		var sim := CitySim.boot_from_files(4242)
		sim.advance_coarse_hours(24 * 4, false)
		assert_true(sim.director.debug_force_director_event(id,
				sim.build_director_inputs(), _ctx(sim.clock.tick_index)),
				"`%s` committed" % id)
		sim.advance_coarse_hours(3, false)
		assert_true(sim._director_links.size() > 0 or sim.director.history.size() > 0,
				("`%s` reached doc 06 and became an incident (open, or one that "
						+ "already closed); on the fork it became nothing") % id)
		sim.dispose()


func test_the_sink_resolves_a_water_segment_the_fork_could_not() -> void:
	# The domain the fork's sink could not resolve at all: it looked every ref up
	# in `sim.buildings` and `sim.grid`, found neither, and returned.
	var sim := CitySim.boot_from_files(4242)
	for source in ["water_segment", "intersection", "building", "transformer"]:
		assert_true(sim.director_fallback_target(source) != "",
				"the starter city has a `%s` candidate" % source)
	sim.incident_sink.request_incident(&"water_main_break", {
		"event_uid": 4242, "ref": sim.director_fallback_target("water_segment"),
		"candidate_source": "water_segment", "severity_mult": 1.0,
		"reason": "director",
	})
	var linked := 0
	for incident_id in sim._director_links:
		if int(sim._director_links[incident_id]) == 4242:
			linked += 1
	assert_eq(linked, 1, "the water main break spawned and is attributable")
	sim.dispose()


func test_the_sink_picks_for_itself_when_the_request_carries_no_reference() -> void:
	# PA-25 item 3. Reachable through the debug verb and through a save whose
	# in-flight row was written before the provider existed.
	var sim := CitySim.boot_from_files(4242)
	# Deterministic FIRST, on two untouched cities: the fallback takes no RNG
	# draw, so two boots of one seed must agree. (Checked before the request
	# below, which sets a building alight and takes it out of the roster.)
	var again := CitySim.boot_from_files(4242)
	for source in ["building", "transformer", "water_segment", "intersection"]:
		assert_eq(sim.director_fallback_target(source),
				again.director_fallback_target(source),
				"`%s`: the fallback cannot desync fine from coarse" % source)
	again.dispose()
	sim.incident_sink.request_incident(&"structure_fire", {
		"event_uid": 77, "ref": "", "candidate_source": "building",
		"severity_mult": 1.0, "reason": "director",
	})
	var linked := 0
	for incident_id in sim._director_links:
		if int(sim._director_links[incident_id]) == 77:
			linked += 1
	assert_eq(linked, 1, "an empty ref is answered by picking, not by refusing")
	sim.dispose()


func test_a_weather_event_still_schedules_with_no_target_roster() -> void:
	# The trap this fix could have walked into: §2.6.3 step 8 says "no legal
	# target → drop the pick", and a weather event has no roster because its
	# target is the whole city. Reading step 8 the other way would delete
	# `storm_minor`, `heat_wave` and the authored thunderstorm from the schedule
	# the moment a provider was bound.
	var sim := CitySim.boot_from_files(4242)
	sim.advance_coarse_hours(24 * 4, false)
	for id in ["storm_minor", "heat_wave", "severe_thunderstorm"]:
		assert_eq(sim.director_targets(id).size(), 0,
				"`%s` has no target roster, by design" % id)
		assert_true(sim.director.debug_force_director_event(id,
				sim.build_director_inputs(), _ctx(sim.clock.tick_index)),
				"`%s` commits anyway" % id)
	sim.dispose()


func test_f10_marks_a_sole_station_and_ships_it_as_a_condition_floor() -> void:
	# F10 is evaluated where "last of its kind" is knowable — the roster — and
	# travels to the resolver as `condition_floor`. Nothing else in the game can
	# make that call.
	var sim := CitySim.boot_from_files(4242)
	var protected: Array = []
	for entry in sim.director_targets("major_structure_fire"):
		var row: Dictionary = entry
		if bool(row.get("f10_protected", false)):
			protected.append(String(row["ref"]))
	assert_true(protected.size() > 0,
			"a starter city has at least one department with a single station")
	var floor_value := sim.director.condition_floor_for({"f10_protected": true})
	assert_almost_eq(floor_value, 0.1, 1e-9, "§2.6.4 F10's floor")
	assert_almost_eq(sim.director.condition_floor_for({}), 0.0, 1e-9,
			"and nothing else is clamped")
	sim.dispose()


# ------------------------------------------------------------------- PA-89

func test_buy_severity_is_all_or_nothing_and_capped_at_the_authored_bonus() -> void:
	var director := _director(31)
	var tables := director.tables
	var storm_row := tables.event_by_id("severe_thunderstorm")   # tp_cost 36
	var minor := tables.event_by_id("traffic_pileup")            # tp_cost 6
	var cap := float(tables.severity["buy_max_cost_mult"])
	var bonus_max := float(tables.severity["buy_max_severity"])
	assert_almost_eq(cap, 1.6, 1e-9, "§2.6.2's spend cap")
	assert_almost_eq(bonus_max, 0.3, 1e-9, "§2.6.2's severity cap")

	# (a) Exactly at the threshold: buy nothing. `tp_pool > 1.6 × cost` is a
	# STRICT inequality in §2.6.2 and a Director that spent its last point would
	# have nothing left for the event it just made worse.
	director.tp_pool = 36.0 * cap
	assert_almost_eq(director.buy_severity_spend_mult(storm_row, [storm_row]), 1.0,
			1e-9, "at the threshold, nothing is bought")
	# (b) Money to spare and NOTHING ELSE AFFORDABLE: buy the cap. §2.6.2's second
	# clause is `pool.size() == 1` — one thing to spend on and a surplus that
	# would otherwise sit against F6's cap.
	director.tp_pool = 120.0
	assert_almost_eq(director.buy_severity_spend_mult(storm_row, [storm_row]),
			cap, 1e-9, "nothing else is affordable, so the surplus buys severity")
	# (c) Another candidate on the table: the budget has somewhere better to go.
	assert_almost_eq(director.buy_severity_spend_mult(storm_row, [storm_row, minor]),
			1.0, 1e-9, "a second affordable candidate stops the buy")
	assert_almost_eq(director.buy_severity_spend_mult(minor, [minor, storm_row]),
			1.0, 1e-9, "…from either side of it")
	# (d) The bonus curve: linear in the overspend, exactly +0.30 at the cap.
	assert_almost_eq(director.severity_buy_bonus(1.0), 0.0, 1e-9)
	assert_almost_eq(director.severity_buy_bonus(cap), bonus_max, 1e-9,
			"1.60 × cost buys exactly +0.30")
	assert_almost_eq(director.severity_buy_bonus(1.3), 0.15, 1e-9,
			"and half the overspend buys half the bonus")
	assert_almost_eq(director.severity_buy_bonus(4.0), bonus_max, 1e-9,
			"the bonus is capped however much is spent")


func test_a_bought_event_costs_what_it_bought_and_hits_harder() -> void:
	var director := _director(33)
	director.tp_pool = 180.0
	var inputs := _inputs()
	var ctx := _ctx(240 * 100)
	director._now_min = ctx.tick_index / GameClock.TICKS_PER_MINUTE
	var event := director.tables.event_by_id("severe_thunderstorm")
	var mult := director.buy_severity_spend_mult(event, [event])
	assert_almost_eq(mult, 1.6, 1e-9, "the pool can afford the buy")
	var pool_before := director.tp_pool
	var p := director.preparedness(inputs)
	var plain := director.severity_for(p, false)
	director._commit(event, {}, inputs, ctx, p,
			director._rng.stream("director"), mult)
	assert_eq(director.scheduled.size(), 1, "it committed")
	var row: Dictionary = director.scheduled[0]
	assert_almost_eq(float(row["severity_mult"]), plain + 0.3, 1e-6,
			"the bought severity is on the row the storm will run at")
	assert_almost_eq(float(row["tp_spent"]), 36.0 * 1.6, 1e-6,
			"and the row records what it actually cost")
	assert_almost_eq(pool_before - director.tp_pool, 36.0 * 1.6, 1e-6,
			"the pool paid for it — a bought event is not a free one")
