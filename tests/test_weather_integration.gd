extends SimTest
## The CitySim wiring, proven against the real starter city.
##
## The three adapter classes below are VERBATIM the ones the integration patch
## adds to `sim/city_sim.gd` (which this subsystem does not edit). Registering
## them on a live `CitySim.scheduler` here is what makes the patch snippet in
## the report a tested artefact rather than a suggestion.


class WeatherPhaseSystem extends SimSystem:
	var sim: CitySim
	var weather: WeatherSystem
	var director: DisasterDirector
	var roster: Array = []
	var roster_min: int = -1

	func _init(p_sim: CitySim, p_weather: WeatherSystem, p_director: DisasterDirector) -> void:
		sim = p_sim
		weather = p_weather
		director = p_director

	func system_id() -> StringName: return &"weather"
	func phase() -> int: return Phase.WEATHER
	func cadence() -> int: return Cadence.EVERY_TICK

	func advance_fine(ctx: TimeContext) -> void:
		weather.tick(ctx)
		_route_lightning(ctx)

	func advance_coarse(ctx: TimeContext) -> void:
		weather.advance_coarse(ctx)
		_route_lightning(ctx)

	## Strikes are generated at P04 and resolved before P06 POWER, so the grid
	## sees the damage in the same tick it was struck.
	func _route_lightning(ctx: TimeContext) -> void:
		if not director.storm.active:
			return
		var now_min: int = ctx.tick_index / GameClock.TICKS_PER_MINUTE
		if now_min != roster_min:
			roster = GridStrikeAdapter.roster(sim.grid)
			roster_min = now_min
		var strikes := director.storm.tick(now_min, float(ctx.dt_game_seconds) / 60.0,
				sim.rng, roster, weather.get_storm_cell(),
				director.target_hard_exclude, director.target_immunity)
		for strike in strikes:
			if String(strike["domain"]) == "grid":
				GridStrikeAdapter.resolve(sim.grid, strike, sim.rng)


class DirectorPhaseSystem extends SimSystem:
	var sim: CitySim
	var director: DisasterDirector
	var inputs_builder: Callable

	func _init(p_sim: CitySim, p_director: DisasterDirector, p_builder: Callable) -> void:
		sim = p_sim
		director = p_director
		inputs_builder = p_builder

	func system_id() -> StringName: return &"director"
	func phase() -> int: return Phase.DIRECTOR
	func cadence() -> int: return Cadence.EVERY_HOUR

	func advance_fine(ctx: TimeContext) -> void:
		director.tick_hour(inputs_builder.call(), ctx)

	func advance_coarse(ctx: TimeContext) -> void:
		advance_fine(ctx)


class WeatherReportPhaseSystem extends SimSystem:
	var sim: CitySim
	var weather: WeatherSystem
	var director: DisasterDirector

	func _init(p_sim: CitySim, p_weather: WeatherSystem, p_director: DisasterDirector) -> void:
		sim = p_sim
		weather = p_weather
		director = p_director

	func system_id() -> StringName: return &"weather_report"
	func phase() -> int: return Phase.REPORT
	func cadence() -> int: return Cadence.EVERY_TICK

	func advance_fine(_ctx: TimeContext) -> void:
		for event in weather.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in director.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)
		for event in director.storm.drain_events():
			sim.bus.emit(StringName(String(event["type"])), event)

	func advance_coarse(ctx: TimeContext) -> void:
		advance_fine(ctx)


# ------------------------------------------------------------------- wiring

func _wire(sim: CitySim) -> Dictionary:
	var weather := WeatherSystem.new(
			WeatherTables.load_from_file("res://data/weather.json"), sim.rng)
	var director := DisasterDirector.new(
			DirectorTables.load_from_file("res://data/director.json"), sim.rng)
	var sink := IncidentRequestSink.Recording.new()
	# Doc 09's map bounds; the starter city is 3×3 developed blocks inside a 7×7
	# grid, so the centre is tile (56, 56) and the bounding radius ~56 tiles.
	weather.set_city_bounds(Vector2(56, 56), 56.0)
	weather.attach_modifiers(sim.modifiers)
	weather.bootstrap(_ctx_of(sim))
	director.attach(weather, sink)
	# Doc 09 owns elevation, per land block (§9 item 8) — the flood field is
	# registered from it and is exactly that coarse, no finer.
	for block_id in sim.world.block_ids_sorted():
		var block: LandBlock = sim.world.block(String(block_id))
		weather.flood.register_block(block.grid.x, block.grid.y,
				String(block.elevation_band()))
	sim.scheduler.register(WeatherPhaseSystem.new(sim, weather, director))
	sim.scheduler.register(DirectorPhaseSystem.new(sim, director,
			func() -> DirectorInputs: return _build_inputs(sim)))
	sim.scheduler.register(WeatherReportPhaseSystem.new(sim, weather, director))
	return {"weather": weather, "director": director, "sink": sink}


func _ctx_of(sim: CitySim) -> TimeContext:
	var ctx := TimeContext.new()
	ctx.tick_index = sim.clock.tick_index
	ctx.minute_of_day = sim.clock.minute_of_day()
	ctx.day_index = sim.clock.day_index()
	ctx.season_index = sim.clock.season_index()
	return ctx


## §2.6.1's input block, assembled from the systems that own each field.
## Water and road redundancy are 0.0 until docs 05 and 10 land — flagged, not
## faked: an absent input lowers preparedness, which lowers pressure, which is
## the safe direction.
func _build_inputs(sim: CitySim) -> DirectorInputs:
	var served := 0
	var total := 0
	for id in sim.buildings:
		total += 1
		if not sim.grid.is_powered(String(id)):
			served += 1
	return DirectorInputs.make({
		"city_age_days": sim.clock.day_index(),
		"season_index": sim.clock.season_index(),
		"population": sim.population.city_population,
		"treasury": sim.treasury.balance,
		"daily_opex": 1,
		"grid_redundancy": 0.0,
		"water_redundancy": 0.0,
		"road_redundancy": 0.0,
		"units_owned": {"fire": 1, "police": 1, "utility": 1, "water": 1, "construction": 1},
		"total_response_units": 5,
		"city_stability": sim.districts.city_stability,
		"customers_out_pct": float(served) / float(maxi(1, total)),
		"roads_impassable_pct": 0.0,
		"difficulty": "standard",
	})


# -------------------------------------------------------------------- tests

func test_weather_runs_in_phase_order_on_the_starter_city() -> void:
	var sim := CitySim.boot_from_files(1337)
	assert_true(sim.boot_errors.is_empty(), "starter city boots")
	var before := sim.scheduler.system_count()
	var rig := _wire(sim)
	assert_eq(sim.scheduler.system_count(), before + 3, "three phase systems registered")
	sim.advance_hours(6.0)
	var weather: WeatherSystem = rig["weather"]
	assert_true(WeatherTables.STATES.has(weather.get_state()), "weather is live")
	assert_true(sim.modifiers.source_count() >= 1, "the weather modifier source is pushed")


func test_weather_moves_power_demand_through_the_modifier_stack() -> void:
	# Core Rule 8: weather is never cosmetic. A heat wave must move real numbers
	# in another system, through the ONE published multiplier interface.
	var clear_sim := CitySim.boot_from_files(4242)
	var clear_rig := _wire(clear_sim)
	var clear_weather: WeatherSystem = clear_rig["weather"]
	clear_weather.timeline.inject_segment("CLEAR", 0, 100000, 0.0, -1, "chain")
	clear_sim.advance_hours(3.0)
	var clear_demand := 0.0
	for id in clear_sim._last_demands:
		clear_demand += float(clear_sim._last_demands[id])

	var hot_sim := CitySim.boot_from_files(4242)
	var hot_rig := _wire(hot_sim)
	var hot_weather: WeatherSystem = hot_rig["weather"]
	hot_weather.timeline.inject_segment("HEAT_WAVE", 0, 100000, 0.80, -1, "chain")
	hot_sim.advance_hours(3.0)
	var hot_demand := 0.0
	for id in hot_sim._last_demands:
		hot_demand += float(hot_sim._last_demands[id])

	assert_true(clear_demand > 0.0, "the clear-sky city draws power")
	var ratio := hot_demand / clear_demand
	assert_almost_eq(ratio, 1.49, 0.001,
			"heat-wave demand is exactly power_load_mult × clear-sky demand")
	assert_true(hot_weather.get_ambient_temp_c() > clear_weather.get_ambient_temp_c() + 10.0,
			"and the grid sees a much hotter ambient for its thermal derate")


func test_grid_env_comes_from_weather_not_a_constant() -> void:
	var sim := CitySim.boot_from_files(7)
	var rig := _wire(sim)
	var weather: WeatherSystem = rig["weather"]
	weather.timeline.inject_segment("HEAT_WAVE", 0, 100000, 1.0, -1, "chain")
	sim.advance_hours(9.0)  # founding is 06:00, so this lands on the 15:00 peak
	var env := weather.env_for_grid()
	assert_true(bool(env["heat_wave"]), "PowerGrid.tick gets heat_wave = true")
	assert_true(float(env["t_ambient_c"]) > 30.0,
			"and a real ambient (%f °C), not the 22.0 stub" % float(env["t_ambient_c"]))
	# cap_eff derates above 30 °C, which is the whole point of publishing it.
	var ids := GridStrikeAdapter.roster(sim.grid)
	assert_true(ids.size() > 0, "the grid has components to derate")
	var id := String(ids[0]["ref"])
	assert_true(sim.grid.cap_eff(id, float(env["t_ambient_c"])) < sim.grid.cap_eff(id, 22.0),
			"a hotter ambient lowers effective capacity")


func test_determinism_with_weather_and_director_attached() -> void:
	var a := CitySim.boot_from_files(2026)
	_wire(a)
	a.advance_hours(24.0)
	var b := CitySim.boot_from_files(2026)
	_wire(b)
	b.advance_hours(24.0)
	assert_eq(JSON.stringify(a.canonical_capture()), JSON.stringify(b.canonical_capture()),
			"24 game-hours with weather + Director stay bit-identical")


func test_storm_damages_the_starter_grid_end_to_end() -> void:
	var sim := CitySim.boot_from_files(99)
	var rig := _wire(sim)
	var weather: WeatherSystem = rig["weather"]
	var director: DisasterDirector = rig["director"]
	sim.bus.drain()
	# Force the reference storm on the city rather than waiting for the budget.
	var now_min: int = sim.clock.tick_index / GameClock.TICKS_PER_MINUTE
	weather.inject_storm(now_min + 30, 120, 1.0, 5001)
	director._now_min = now_min
	director._start_event({"event_uid": 5001, "type": "severe_thunderstorm",
			"impact_min": now_min + 30, "warned": true, "severity_mult": 1.4,
			"hazard_tier": 3, "class": "major", "tp_cost": 36, "target": {},
			"scheduled_min": now_min, "warn_lead_min": 90, "intensity": 1.0,
			"duration_min": 120}, _build_inputs(sim))
	sim.advance_hours(3.0)
	var strikes: Array = []
	for event in sim.bus.drain():
		if event["type"] == &"lightning_strike":
			strikes.append(event)
	assert_true(strikes.size() > 0, "the storm put %d strikes on the bus" % strikes.size())
	var asset_strikes := 0
	for strike in strikes:
		if String(strike["target_ref"]) != "":
			asset_strikes += 1
			assert_true(sim.grid.component(String(strike["target_ref"])).size() > 0,
					"every asset strike names a real grid component")
	assert_true(asset_strikes > 0, "%d asset strikes resolved into doc 04" % asset_strikes)
	# F10: the starter city has one plant and one substation. Neither may be
	# pushed below 0.10 nor destroyed, however hard the storm hits.
	for entry in GridStrikeAdapter.roster(sim.grid):
		if bool(entry["f10_protected"]):
			var component := sim.grid.component(String(entry["ref"]))
			assert_true(float(component["condition"]) >= 0.10 - 1e-9,
					"%s stayed above the F10 floor" % entry["ref"])
			assert_ne(String(component.get("failed_cause", "")), "LIGHTNING_DESTROYED",
					"%s is damaged, never destroyed" % entry["ref"])


func test_flood_field_registers_from_doc_09_blocks() -> void:
	var sim := CitySim.boot_from_files(5)
	var rig := _wire(sim)
	var weather: WeatherSystem = rig["weather"]
	var blocks := sim.world.block_ids_sorted().size()
	assert_true(blocks > 0, "the starter city has %d land blocks" % blocks)
	assert_eq(weather.flood.registered_count(), blocks,
			"one flood cell per land block, not per tile")
	var low := 0
	for block_id in sim.world.block_ids_sorted():
		if String(sim.world.block(String(block_id)).elevation_band()) == "LOW":
			low += 1
	assert_true(low > 0, "%d LOW blocks can flood" % low)
	weather.timeline.inject_segment("THUNDERSTORM", 0, 100000, 1.0, -1, "chain")
	sim.advance_hours(1.0)
	assert_almost_eq(weather.get_precip_mm_h(), 35.0, 1e-9, "peak precipitation")
	assert_true(weather.flood.flood_saturation_city() > 0.0,
			"LOW blocks accumulate water during the storm")
