extends SimTest
## **99-PA PA-04 / A91-D-59 — the Disaster Director's stall, and its repair.**
##
## At the Wave-17 fork nothing in `sim/` or `game/` called
## `DisasterDirector.on_event_resolved`. The only eraser of `active_events` had
## one caller in the whole tree — this suite — so in a played city the list only
## ever grew, `_try_schedule`'s two-in-flight gate refused every later schedule,
## and after its first two minor events the Director went silent for the rest of
## the city's life. Measured on the fork, `tools/probe_director.gd`, balanced /
## seed 4242 / 60 game-days: **2 events started, 0 ended, `active_end = 2` from
## game-day 8 to the end.** Doc 07 §2.6's "one crisis every 2–2.5 game-days" and
## the whole §2.7 thunderstorm beat sheet were unreachable.
##
## The repair is one idea in three places: every committed row is STAMPED at
## commit with the two minutes that end it (`resolve_after_min`, `expire_at_min`),
## `CitySim` joins that clock to its incident link book on every REPORT tick, and
## the save ladder's rung 8 writes the stamp onto every row of every save that
## was written before it existed.

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


# ------------------------------------------------------------- the two knobs

func test_the_hold_cap_lives_in_one_place_with_a_mirror_the_migrator_can_read() -> void:
	# Doc 08 §2.8 forbids a save migrator from opening `data/`, so rung 8 reads
	# constants. A constant that drifted from the table it mirrors would migrate
	# old saves onto a deadline the live game does not use.
	var tables := DirectorTables.load_from_file(DIRECTOR_DATA)
	assert_eq(int(tables.fairness["max_active_min"]),
			DisasterDirector.MAX_ACTIVE_MIN_DEFAULT,
			"data/director.json fairness.max_active_min and the constant agree")
	assert_eq(int((tables.storm["recovery"] as Dictionary)["report_at_min"]),
			DisasterDirector.STORM_REPORT_AT_MIN_DEFAULT,
			"§2.7.6's report beat and the constant agree")
	assert_eq(DisasterDirector.MAX_ACTIVE_MIN_DEFAULT, 2880,
			"the hold cap is 48 game-hours (99-PA PA-04's gate)")


# ------------------------------------------------------------------ the stamp

func test_every_committed_event_carries_the_two_minutes_that_end_it() -> void:
	var director := _director(4242)
	var inputs := _inputs()
	var seen := 0
	for hour in 400:
		director.tp_pool = 180.0
		director.tick_hour(inputs, _ctx(hour * GameClock.TICKS_PER_HOUR))
		for row in director.scheduled:
			seen += 1
			assert_true(row.has("resolve_after_min"),
					"a scheduled row with no earliest-resolution minute")
			assert_true(row.has("expire_at_min"), "…and no hold cap")
			assert_eq(int(row["expire_at_min"]),
					int(row["impact_min"]) + DisasterDirector.MAX_ACTIVE_MIN_DEFAULT,
					"the cap is measured from impact")
			assert_true(int(row["resolve_after_min"]) >= int(row["impact_min"]),
					"an event cannot end before it starts")
	assert_true(seen > 0, "the drive committed something to inspect (%d rows)" % seen)


func test_a_weather_event_is_not_over_while_its_segment_is_still_running() -> void:
	var director := _director(7)
	# A `storm_minor` row, stamped as `_commit` stamps it.
	var row := {"event_uid": 1, "type": "storm_minor", "impact_min": 1000,
			"duration_min": 90, "class": "minor"}
	director._stamp_resolution(row)
	assert_eq(int(row["resolve_after_min"]), 1090,
			"impact + duration: the segment has to finish first")
	# §2.7.6: the storm also owes the player a report at T+180, and the beat
	# sheet's 120-minute storm therefore ends at exactly T+180.
	var storm := {"event_uid": 2, "type": "severe_thunderstorm", "impact_min": 1000,
			"duration_min": 120, "class": "major"}
	director._stamp_resolution(storm)
	assert_eq(int(storm["resolve_after_min"]), 1180,
			"impact + max(duration, report_at_min) — doc 07 §2.7.6's T+180 beat")
	var long_storm := {"event_uid": 3, "type": "severe_thunderstorm",
			"impact_min": 1000, "duration_min": 240, "class": "major"}
	director._stamp_resolution(long_storm)
	assert_eq(int(long_storm["resolve_after_min"]), 1240,
			"…and a storm longer than the beat ends with the storm")
	# An event that only requests incidents may end the moment they close.
	var pileup := {"event_uid": 4, "type": "traffic_pileup", "impact_min": 1000,
			"class": "minor"}
	director._stamp_resolution(pileup)
	assert_eq(int(pileup["resolve_after_min"]), 1000, "no segment to wait for")


# --------------------------------------------------------- the clock half

func test_an_event_with_an_incident_still_open_is_not_resolved() -> void:
	var director := _director(11)
	director._now_min = 2000
	var row := {"event_uid": 9, "type": "traffic_pileup", "impact_min": 1000,
			"class": "minor", "severity_mult": 1.0, "target": {},
			"resolve_after_min": 1000, "expire_at_min": 1000 + 2880}
	director.active_events[9] = row
	assert_eq(director.events_due_for_resolution(2000, {9: true}).size(), 0,
			"an open incident holds its event open")
	var due := director.events_due_for_resolution(2000, {})
	assert_eq(due.size(), 1, "…and nothing holds it once the last one closes")
	assert_eq(int(due[0][0]), 9)
	assert_eq(String(due[0][1]), DisasterDirector.OUTCOME_RESOLVED)


func test_the_hold_cap_ends_an_event_whose_link_book_lost_it() -> void:
	# The failure mode the cap exists for: an incident closed on a path that did
	# not erase its link, or a save arrived with a link book that never matched.
	# Without the cap this row is immortal and the Director is over.
	var director := _director(12)
	var row := {"event_uid": 3, "type": "major_structure_fire", "impact_min": 1000,
			"class": "major", "severity_mult": 1.0, "target": {},
			"resolve_after_min": 1000, "expire_at_min": 1000 + 2880}
	director.active_events[3] = row
	assert_eq(director.events_due_for_resolution(3879, {3: true}).size(), 0,
			"one minute short of the cap, a busy event still holds")
	var due := director.events_due_for_resolution(3880, {3: true})
	assert_eq(due.size(), 1, "at the cap it ends however busy it claims to be")
	assert_eq(String(due[0][1]), DisasterDirector.OUTCOME_EXPIRED,
			"and it ends as EXPIRED, so the history row says what happened")


func test_two_events_closing_on_one_tick_close_in_uid_order() -> void:
	var director := _director(13)
	for uid in [7, 2, 5]:
		director.active_events[uid] = {"event_uid": uid, "type": "traffic_pileup",
				"impact_min": 100, "class": "minor", "severity_mult": 1.0,
				"target": {}, "resolve_after_min": 100, "expire_at_min": 2980}
	var order: Array = []
	for entry in director.events_due_for_resolution(200, {}):
		order.append(int(entry[0]))
	assert_eq(order, [2, 5, 7], "ascending uid — determinism, not dictionary order")


# ------------------------------------------------------ the played city

func test_a_played_city_resolves_its_events_and_keeps_scheduling() -> void:
	# The whole defect in one assertion. Eighteen game-days is enough for the
	# fork's two-event stall to have set in (it did so by game-day 8).
	var sim := CitySim.boot_from_files(4242)
	var started := 0
	var ended := 0
	sim.bus.drain()
	for _hour in 18 * 24:
		sim.advance_coarse_hours(1, false)
		for event in sim.bus.drain():
			match String(event.get("type", "")):
				"director_event_started":
					started += 1
				"director_event_ended":
					ended += 1
	assert_true(started >= 3,
			"the fork stalled at two; this run started %d" % started)
	assert_true(ended >= started - 2,
			"%d started and only %d ended — something is being held" % [started, ended])
	assert_true(sim.director.active_events.size() <= 2,
			"the in-flight list is bounded by the pacing gate itself")
	assert_eq(sim.director.history.size(), ended,
			"every resolution wrote its history row")
	for row in sim.director.history:
		assert_true(int(row["end_min"]) - int(row["start_min"])
				<= DisasterDirector.MAX_ACTIVE_MIN_DEFAULT,
				"an event was held %d game-minutes, past the 48-game-hour cap"
						% [int(row["end_min"]) - int(row["start_min"])])
	sim.dispose()


func test_the_authored_thunderstorm_runs_schedule_to_report() -> void:
	# 99-PA PA-04's other half: the §2.7 beat sheet has to be REACHABLE. Forced
	# rather than waited for — a major costs 36 TP and a founding city takes
	# weeks to save that — but everything after the force is the shipping path.
	var sim := CitySim.boot_from_files(4242)
	sim.advance_coarse_hours(24 * 4, false)   # past F1's grace
	var ctx := _ctx(sim.clock.tick_index)
	assert_true(sim.director.debug_force_director_event("severe_thunderstorm",
			sim.build_director_inputs(), ctx), "the catalog row exists and commits")
	var uid := -1
	for row in sim.director.scheduled:
		if String(row["type"]) == "severe_thunderstorm":
			uid = int(row["event_uid"])
	assert_true(uid > 0, "it is on the schedule")
	var warned := false
	for event in sim.director.drain_events():
		if String(event["type"]) == "weather_warning":
			warned = true
			assert_eq(String(event["kind"]), "severe_thunderstorm")
			assert_eq(String(event["notify_class"]), "CRITICAL", "F7")
	assert_true(warned, "F7's warning went out at commit")
	# Warning lead 90 min, storm 90–180 min, report at T+180: 12 game-hours is
	# past every one of them.
	sim.advance_coarse_hours(12, false)
	assert_false(sim.director.active_events.has(uid),
			"the storm resolved: schedule → warning → storm → report")
	var found := false
	for row in sim.director.history:
		if String(row["type"]) == "severe_thunderstorm":
			found = true
	assert_true(found, "and it is in the Director's history")
	assert_false(sim.director.storm.active, "the storm module stood down")
	sim.dispose()


# ------------------------------------------------------- the save ladder

## A v7 body with two ghost events in it — the state every save on every phone
## can be in. `impact_min` is 30 game-days back, so under v8 both are past their
## hold cap the moment the city ticks.
func _v7_body_with_two_ghosts() -> Dictionary:
	var sim := CitySim.boot_from_files(4242)
	var body := sim.capture_state()
	sim.dispose()
	var director_block: Dictionary = body["director"]
	director_block["active_events"] = [
		{"event_uid": 1, "type": "traffic_pileup", "impact_min": 1440,
				"warned": false, "severity_mult": 1.0, "hazard_tier": 1,
				"class": "minor", "tp_cost": 6, "target": {}, "scheduled_min": 1400,
				"warn_lead_min": 0},
		{"event_uid": 2, "type": "storm_minor", "impact_min": 2880,
				"warned": true, "severity_mult": 1.0, "hazard_tier": 1,
				"class": "minor", "tp_cost": 8, "target": {}, "scheduled_min": 2820,
				"warn_lead_min": 60, "duration_min": 60},
	]
	director_block["next_event_uid"] = 3
	director_block["tp_pool"] = 120.0
	body["director"] = director_block
	body["section_version"] = 7
	return body


func test_rung_eight_stamps_a_ghost_pair_so_it_can_die() -> void:
	var sim := CitySim.boot_from_files(4242)
	var migrated := sim.migrate_save_section(_v7_body_with_two_ghosts(), 7)
	var rows: Array = (migrated["director"] as Dictionary)["active_events"]
	assert_eq(rows.size(), 2, "the migrator adds and removes no rows")
	for raw in rows:
		var row: Dictionary = raw
		assert_true(row.has("resolve_after_min") and row.has("expire_at_min"),
				"every ghost left the migrator with a way to end")
		assert_eq(int(row["expire_at_min"]),
				int(row["impact_min"]) + DisasterDirector.MAX_ACTIVE_MIN_DEFAULT,
				"stamped from what the row already carried, and the constant")
	assert_eq(int((rows[1] as Dictionary)["resolve_after_min"]), 2880 + 60,
			"the weather ghost waits out the segment it claimed to have")
	sim.dispose()


func test_a_stalled_save_wakes_up_when_it_is_loaded() -> void:
	# The player's side of the rung, end to end: the ghost pair goes in, the
	# city comes back, and the Director is scheduling again inside a game-week.
	var sim := CitySim.boot_from_files(4242)
	sim.restore_state(sim.migrate_save_section(_v7_body_with_two_ghosts(), 7))
	assert_eq(sim.director.active_events.size(), 2, "the stall loaded as it was")
	assert_true(sim.director.has_pending_event(),
			"…and the pacing gate is shut, exactly as it was on the phone")
	# The younger ghost's own clock (`impact 2880 + duration 60`) is the later of
	# the two, so 72 game-hours clears both. Neither needs the hold cap: nothing
	# holds them, which is exactly the point — a ghost is a row with no incident
	# behind it, and the ordinary path now sees that. The cap is the last resort
	# (`test_the_hold_cap_ends_an_event_whose_link_book_lost_it`), not the only one.
	sim.advance_coarse_hours(72, false)
	assert_eq(sim.director.active_events.size(), 0, "both ghosts are gone")
	assert_eq(sim.director.history.size(), 2, "both recorded, neither invented")
	var outcomes: Dictionary = {}
	for row in sim.director.history:
		outcomes[String(row["type"])] = String(row["outcome"])
	assert_eq(String(outcomes["storm_minor"]), DisasterDirector.OUTCOME_RESOLVED,
			"the weather ghost ended when its segment had")
	assert_eq(String(outcomes["traffic_pileup"]), DisasterDirector.OUTCOME_RESOLVED,
			"and the incident ghost the moment nothing was open under it")
	var started := 0
	sim.bus.drain()
	for _hour in 7 * 24:
		sim.advance_coarse_hours(1, false)
		for event in sim.bus.drain():
			if String(event.get("type", "")) == "director_event_started":
				started += 1
	assert_true(started >= 1,
			"a repaired save schedules again; this one started %d in a game-week"
					% started)
	sim.dispose()


func test_a_pre_rung_eight_row_is_stamped_even_without_the_ladder() -> void:
	# The second belt: a fragment restored by a test, a tool or a fixture that
	# never went through `migrate_save_section` still gets a stamp, because
	# `deserialize` writes one when the row arrives without it.
	var director := _director(21)
	director.deserialize({"active_events": [
		{"event_uid": 4, "type": "water_main_break", "impact_min": 500,
				"class": "minor", "severity_mult": 1.0, "target": {}},
	]})
	var row: Dictionary = director.active_events[4]
	assert_true(row.has("expire_at_min"), "stamped on the way in")
	assert_eq(int(row["expire_at_min"]), 500 + DisasterDirector.MAX_ACTIVE_MIN_DEFAULT)
