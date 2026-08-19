extends SimTest
## Doc 06 §7 math tests: the escalation ladder, the three fire channels,
## suppression sizing derived from doc 02's `fire_load`, the work re-queue on a
## tier change, and the hazard-rate composition that makes fine and coarse
## stepping agree.

const CLEAR_ESC_ENV := 1.250


func _catalog() -> IncidentCatalog:
	return IncidentCatalog.load_from_files()


func _system(world: IncidentTestWorld, seed_value: int = 1337) -> IncidentSystem:
	var system := IncidentSystem.new(_catalog(), world, RngStreams.new(seed_value))
	system.generation_enabled = false
	return system


## Wood house L2 with the §2.4 worked example's inputs.
func _fire_world(wind_kph: float = 45.0, hydrant: float = 1.0) -> IncidentTestWorld:
	var world := IncidentTestWorld.new()
	world.add_district("D1", 6000.0, 0.55)
	world.add_building("B1", "house", 2, Vector2i(10, 10), "D1",
			{"fire_load": 40.0, "occupants": 6.0})
	world.wind = wind_kph
	world.hydrant_ratio = hydrant
	return world


func test_catalog_loads_clean() -> void:
	var catalog := _catalog()
	assert_true(catalog.is_valid(),
			"incidents/vehicles/dispatch data clean: %s" % str(catalog.errors))
	assert_true(catalog.has_type("structure_fire"), "structure_fire type present")
	assert_true(catalog.has_type("storm_damage"), "storm_damage type present")
	assert_eq(catalog.type_row("storm_damage", "blocked_road").get("primary_role", ""),
			"construction", "subtype overrides the parent's primary role")
	assert_eq(catalog.type_row("storm_damage", "blocked_road").get("reward_base", 0), 400,
			"subtype inherits the parent's reward_base")


## Doc 06 §7 test 5 / 41 — esc_env driven through the LIVE doc 07 channel.
func test_escalation_table_clear() -> void:
	var world := _fire_world()
	world.weather_channels["fire_escalation_mult"] = 1.0
	var system := _system(world)
	var inc := system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "B1"}, 1.0)
	assert_almost_eq(system.esc_env(inc, 0.0), CLEAR_ESC_ENV, 1e-6, "esc_env CLEAR")
	# The tier ladder: 2.20 × (1 + 0.25·(tier−1)) × 1.25.
	var expected := [2.750, 3.4375, 4.125, 4.8125]
	for i in 4:
		inc.severity = float(i + 1)
		assert_almost_eq(system.escalation_rate(inc, 0.0), expected[i], 1e-6,
				"tier %d escalation rate" % (i + 1))
	# §2.13's published entry point is the delta form; it is a thin wrapper over
	# the absolute-time one the adapter uses.
	inc.severity = 1.0
	system.advance(1.0 / 60.0)
	assert_almost_eq(system.now_h, 1.0 / 60.0, 1e-12, "advance(dt_h) moved the clock")
	assert_almost_eq(inc.severity, 1.0 + 2.750 / 60.0, 1e-9, "and integrated one game-minute")


## Doc 06 §7 test 41 — golden tier-arrival times, and the C-70 invariant that
## the worst mature-city response (39.1 gm) still beats tier 3 (39.273 gm).
func test_tier_arrival_times_and_response_band() -> void:
	var world := _fire_world()
	world.weather_channels["fire_escalation_mult"] = 1.0
	var system := _system(world)
	system.spawn("structure_fire", "", Vector2i(10, 10), {"kind": "building", "id": "B1"}, 1.0)
	var arrivals: Dictionary = {}
	for minute in 90:
		system.advance_to(float(minute + 1) / 60.0)
		for event in system.drain_events():
			if String(event.get("type", "")) == "incident_tier_changed":
				var tier := int(event["tier"])
				if not arrivals.has(tier):
					arrivals[tier] = float(event["at_h"]) * 60.0
	assert_almost_eq(float(arrivals.get(2, -1.0)), 21.818, 0.1, "tier 2 at 21.8 gm")
	assert_almost_eq(float(arrivals.get(3, -1.0)), 39.273, 0.1, "tier 3 at 39.3 gm")
	assert_almost_eq(float(arrivals.get(5, -1.0)), 66.286, 0.15, "tier 5 at 66.3 gm")
	assert_true(float(arrivals.get(3, -1.0)) > 39.1,
			"C-70: the 39.1 gm mature-city worst case arrives strictly before tier 3")


## Doc 06 §7 test 41 — the storm cross-check the ruling promised reproduces
## exactly, plus intensity invariance and the no-clamp contract.
func test_esc_env_consumes_fire_escalation_mult() -> void:
	var world := _fire_world(72.4, 1.0)
	world.weather_channels["fire_escalation_mult"] = 0.80
	var system := _system(world)
	var inc := system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "B1"}, 1.0)
	assert_almost_eq(system.esc_env(inc, 0.0), 1.2192, 1e-6, "THUNDERSTORM 0.77 esc_env")
	inc.severity = 1.0
	assert_almost_eq(system.escalation_rate(inc, 0.0), 2.68224, 1e-6, "tier-1 storm rate")
	assert_almost_eq(60.0 / 2.68224, 22.37, 0.01, "tier 2 at 22.37 gm")
	# UNCLAMPED: doc 06's [0.4, 3.0] clamp binds only the factors doc 06 authors.
	world.weather_channels["fire_escalation_mult"] = 5.0
	var wind_term := 1.0 + 0.010 * (72.4 - 20.0)
	assert_almost_eq(system.esc_env(inc, 0.0), wind_term * 5.0, 1e-6,
			"doc 07's channel is passed through unclamped")
	world.weather_channels["fire_escalation_mult"] = 0.01
	assert_almost_eq(system.esc_env(inc, 0.0), wind_term * 0.01, 1e-6,
			"and unclamped at the bottom too")


## Doc 06 §7 test 6 — one engine at hydrant ratio 0.4 on a tier-3 house L2.
func test_partial_suppression() -> void:
	var world := _fire_world(45.0, 0.4)
	world.weather_channels["fire_escalation_mult"] = 1.0
	var system := _system(world)
	system.fleet.populate_from_stations([{"id": "FIRE-1", "archetype": "fire_station",
			"level": 1, "tile": Vector2i(10, 10)}])
	var inc := system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "B1"}, 3.0)
	assert_almost_eq(system.required_rate(inc), 0.887926, 0.0005, "required_rate T3 house L2")
	var engine: Vehicle = system.fleet.unit(system.fleet.unit_ids()[0])
	inc.assigned[engine.id] = {"role": "fire", "state": Vehicle.ON_SCENE, "eta_h": 0.0,
			"manual": false}
	engine.status = Vehicle.ON_SCENE
	engine.role = "fire"
	assert_almost_eq(system.assigned_effective_rate(inc), 0.55, 1e-6,
			"hydrant_factor 0.25 + 0.75·0.4 = 0.55")
	assert_almost_eq(system.assist_ratio(inc), 0.619420, 0.001, "assist_ratio")
	var assist := system.assist_ratio(inc)
	# Doc 06 §2.4's printed 1.5699 is `4.125 × (1 − assist)` — the tier-3 rate
	# from the hydrant-1.0 example. The same section's `esc_env[structure_fire]`
	# also multiplies in `hydrant_penalty`, which at ratio 0.4 is 1.257143, so
	# the two statements disagree. The FORMULA is normative here; the printed
	# figure is asserted separately so a future retune cannot hide the gap.
	assert_almost_eq(4.125 * (1.0 - assist), 1.5699, 0.01,
			"§2.4's printed figure, computed without the hydrant penalty")
	var penalty := system.spread.hydrant_penalty(inc.tile)
	assert_almost_eq(penalty, 1.0 + 0.6 * 0.3 / 0.7, 1e-6, "hydrant_penalty at ratio 0.4")
	assert_almost_eq(system.escalation_rate(inc, 0.0) * (1.0 - assist),
			4.125 * penalty * (1.0 - assist), 1e-6,
			"the implemented esc_env includes hydrant_penalty, per the §2.4 formula")


## Doc 06 §7 test 25 (C-43 / R-12) — S_req for all 60 archetype × level pairs
## comes from doc 02's fire_load and nothing else.
func test_s_req_from_fire_load() -> void:
	var catalog := _catalog()
	var buildings := BuildingCatalog.new(
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"))
	assert_true(buildings.is_valid(), "doc 02 catalog loaded")
	var checked := 0
	for archetype in buildings.archetypes():
		for level in range(1, 6):
			var fire_load := float(buildings.stats(String(archetype), level).get("fire_load", 0))
			if fire_load <= 0.0:
				continue
			assert_almost_eq(catalog.s_req_for_fire_load(fire_load),
					0.50 * pow(fire_load / 20.0, 0.45), 1e-6,
					"%s L%d" % [archetype, level])
			checked += 1
	assert_true(checked >= 60, "checked all 60 rows, got %d" % checked)
	assert_almost_eq(catalog.s_req_for_fire_load(20.0), 0.500, 1e-6, "house L1 anchor")
	assert_almost_eq(catalog.s_req_for_fire_load(1120.0), 3.060, 0.001, "high_rise L5")
	assert_almost_eq(catalog.s_req_for_fire_load(1440.0), 3.426, 0.001, "power_facility L5")
	# The deleted tables must be gone, not defaulted.
	var raw := StarterCityLoader.read_json("res://data/incidents.json")
	assert_false(JSON.stringify(raw).contains("s_req_base_by_archetype"),
			"no s_req_base_by_archetype")
	assert_false(JSON.stringify(raw).contains("s_level_slope"), "no s_level_slope")
	assert_false(JSON.stringify(raw).contains("base_fire_risk_by_archetype"),
			"no base_fire_risk_by_archetype")


## Doc 06 §7 test 8 — progress rescales by W_old / W_new on a tier entry.
func test_work_requeue_on_tier_change() -> void:
	var world := _fire_world()
	world.weather_channels["fire_escalation_mult"] = 1.0
	var system := _system(world)
	var inc := system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "B1"}, 1.90)
	assert_almost_eq(system.work_required_at(inc, 1), 0.30, 1e-9, "W at tier 1")
	assert_almost_eq(system.work_required_at(inc, 2), 0.435, 1e-9, "W at tier 2")
	inc.progress = 0.50
	inc.status = Incident.STATUS_ACTIVE
	system.advance_to(0.05)
	assert_eq(inc.tier(), 2, "crossed into tier 2")
	assert_true(inc.progress < 0.50, "effective completion slipped backwards")
	assert_almost_eq(inc.progress, 0.50 * 0.30 / 0.435, 1e-6, "progress × W_old/W_new")
	assert_true(inc.progress >= 0.0 and inc.progress <= 1.0, "progress stays in [0,1]")


## Doc 06 §7 test 9 — P(no ignition) over 1 gh equals exp(−rate) at both
## 5-minute and 1-hour granularity, and the weather channel enters the HAZARD
## RATE rather than the per-roll probability (RR-15).
func test_hazard_rate_composition() -> void:
	for channel_value in [1.0, 0.35]:
		var rate: float = 0.575027 * float(channel_value)
		var p_hour := FireSpread.interval_probability(rate, 1.0)
		var survive := 1.0
		for i in 12:
			survive *= 1.0 - FireSpread.interval_probability(rate, 1.0 / 12.0)
		assert_almost_eq(1.0 - survive, p_hour, 1e-9,
				"12 five-minute rolls == one hourly roll at g_weather %f" % float(channel_value))
		assert_almost_eq(survive, exp(-rate), 1e-9, "P(no ignition) == exp(-rate)")


## Doc 06 §7 test 42 — the §2.8 four-weather table, on the fixed geometry.
func test_spread_consumes_fire_spread_mult() -> void:
	var world := IncidentTestWorld.new()
	world.add_district("D1", 1000.0, 0.8)
	world.add_building("A", "apartment", 2, Vector2i(0, 0), "D1", {"fire_load": 90.0})
	world.add_building("B", "house", 2, Vector2i(2, 0), "D1", {"fire_load": 40.0})
	world.wind_dir = 0.0  # blowing straight at the target ⇒ cos θ = 1
	var system := _system(world)
	var source := system.spawn("structure_fire", "", Vector2i(0, 0),
			{"kind": "building", "id": "A"}, 3.0)
	var rows := [
		{"wind": 10.0, "channel": 1.05, "rate": 0.362267},
		{"wind": 10.2, "channel": 1.63, "rate": 0.564251},
		{"wind": 50.0, "channel": 0.545455, "rate": 0.313651},
		{"wind": 72.4, "channel": 0.4845, "rate": 0.341007},
	]
	for row in rows:
		var entry: Dictionary = row
		world.wind = float(entry["wind"])
		world.weather_channels["fire_spread_mult"] = float(entry["channel"])
		var rate: float = system.spread.spread_rate(source, "B", 0.0, 4, 14.0)
		assert_almost_eq(rate, float(entry["rate"]), 1e-6,
					"spread rate at wind %f channel %f" % [entry["wind"], entry["channel"]])
	# Removing g_weather reproduces the pre-RR-15 figure at the reference storm.
	world.wind = 72.4
	world.weather_channels["fire_spread_mult"] = 1.0
	assert_almost_eq(system.spread.spread_rate(source, "B", 0.0, 4, 14.0), 0.703833, 1e-6,
			"the pre-RR-15 dry-air rate — the regression this test exists to catch")
	# One engine on it takes the rate to zero, in any weather.
	assert_almost_eq(system.spread.spread_rate(source, "B", 1.0, 4, 14.0), 0.0, 1e-12,
			"assist_ratio 1.0 stops spread")


## Doc 06 §7 test 43 — three fire questions, three channels, three call sites,
## none substitutable, and wind is never double-counted.
func test_three_fire_channels_are_not_aliased() -> void:
	var world := _fire_world(72.4, 1.0)
	world.add_building("B2", "house", 2, Vector2i(11, 10), "D1", {"fire_load": 40.0})
	world.weather_channels["fire_ignition_mult"] = 2.724
	world.weather_channels["fire_escalation_mult"] = 0.80
	world.weather_channels["fire_spread_mult"] = 0.4845
	var system := _system(world)
	var inc := system.spawn("structure_fire", "", Vector2i(10, 10),
			{"kind": "building", "id": "B1"}, 3.0)
	world.channel_reads.clear()
	var esc := system.esc_env(inc, 0.0)
	var spread_rate := system.spread.spread_rate(inc, "B2", 0.0, 4, 14.0)
	var seen: Dictionary = {}
	for channel in world.channel_reads:
		seen[String(channel)] = true
	assert_true(seen.has("fire_escalation_mult"), "escalation reads its own channel")
	assert_true(seen.has("fire_spread_mult"), "spread reads its own channel")
	assert_false(seen.has("fire_ignition_mult"),
			"ignition's channel is never read outside generation")
	assert_almost_eq(esc, (1.0 + 0.010 * 52.4) * 0.80, 1e-6, "escalation used 0.80")
	assert_true(spread_rate > 0.0, "spread rate computed")
	# Wind enters spread only through g_wind: stubbing the channel to 1.0 must
	# leave the wind term untouched.
	world.weather_channels["fire_spread_mult"] = 1.0
	var dry := system.spread.spread_rate(inc, "B2", 0.0, 4, 14.0)
	assert_almost_eq(spread_rate / dry, 0.4845, 1e-6,
			"the channel is a clean common factor — no wind double-count")


## Doc 06 §7 test 2 — the analytic day/night split the integrator relies on.
func test_dark_fraction_is_analytic() -> void:
	var world := IncidentTestWorld.new()
	var system := _system(world)
	system.founding_offset_h = 6.0  # tick 0 is 06:00
	# 06:00 → 07:00 is fully daylight.
	assert_almost_eq(system._dark_fraction(0.0, 1.0), 0.0, 1e-9, "06:00-07:00 is day")
	# 06:00 → 06:00 next day: night is 19:00-06:00 = 11 of 24 hours.
	assert_almost_eq(system._dark_fraction(0.0, 24.0), 11.0 / 24.0, 1e-9, "a whole day")
	# 18:00 → 20:00 (12 h → 14 h after founding) is half night.
	assert_almost_eq(system._dark_fraction(12.0, 14.0), 0.5, 1e-9, "straddling 19:00")
	# One coarse hour equals sixty fine minutes, exactly — this is why offline
	# and online agree.
	var coarse := system._dark_fraction(12.0, 13.0)
	var fine := 0.0
	for i in 60:
		fine += system._dark_fraction(12.0 + float(i) / 60.0, 12.0 + float(i + 1) / 60.0) / 60.0
	assert_almost_eq(coarse, fine, 1e-9, "coarse == Σ fine")


## Doc 06 §7 test 2 — tier entries land on the same game-minute whether the
## engine is stepped by the minute or by the hour.
func test_substep_boundary_exactness() -> void:
	var fine_arrivals := _run_fire_arrivals(1.0 / 60.0)
	var coarse_arrivals := _run_fire_arrivals(1.0)
	for tier in [2, 3, 4, 5]:
		assert_true(fine_arrivals.has(tier), "fine run reached tier %d" % tier)
		assert_true(coarse_arrivals.has(tier), "coarse run reached tier %d" % tier)
		assert_almost_eq(float(coarse_arrivals[tier]), float(fine_arrivals[tier]), 0.02,
				"tier %d entry within one game-second across step sizes" % tier)


func _run_fire_arrivals(step_h: float) -> Dictionary:
	var world := _fire_world()
	world.weather_channels["fire_escalation_mult"] = 1.0
	var system := _system(world)
	system.spawn("structure_fire", "", Vector2i(10, 10), {"kind": "building", "id": "B1"}, 1.0)
	var arrivals: Dictionary = {}
	var steps := int(round(2.0 / step_h))
	for i in steps:
		system.advance_to(float(i + 1) * step_h)
		for event in system.drain_events():
			if String(event.get("type", "")) == "incident_tier_changed":
				var tier := int(event["tier"])
				if not arrivals.has(tier):
					arrivals[tier] = float(event["at_h"]) * 60.0
	return arrivals
