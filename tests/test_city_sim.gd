extends SimTest
## The Milestone 1 harness core: the starter city boots, the night peak
## matches doc 09's table, F_SOUTH darkens exactly its subtree, and 24
## game-hours run deterministically (byte-identical state hashes).


func test_boot_loads_everything() -> void:
	var sim := CitySim.boot_from_files()
	assert_true(sim.boot_errors.is_empty(), ", ".join(sim.boot_errors))
	assert_eq(sim.buildings.size(), 34, "the authored manifest")
	assert_eq(sim.world.block_count(), 49)
	assert_eq(sim.districts.district_ids_sorted().size(), 4)
	assert_eq(sim.clock.hour_of_day(), 6, "founded at dawn")
	# Grid: plant + substation + 2 feeders + 1 transmission + 23 transformers.
	assert_eq(sim.grid.grid_inventory()["nodes"].size(), 19,
			"substation + 18 transformers (doc 92 F-4 thinned the roster from 23)")
	assert_eq(sim.grid.grid_inventory()["plants"].size(), 1)


func test_night_peak_matches_doc09_table() -> void:
	# Doc 09 §2.9.4 / doc 04 §2.13 authored 783.3 kW at the 20:00 peak with the
	# HELD water metering (the L1-variant constants). Doc 05's live node roster
	# meters the real plant — heavier than the L1 table by ~18.4 kW — so the
	# as-integrated peak is 801.7 kW. Doc 93 tracks the doc 09 §2.9.4 worked-
	# example refresh; the CHAIN this test guards is unchanged.
	var sim := CitySim.boot_from_files()
	sim.advance_hours(14.0)  # 06:00 → 20:00
	assert_eq(sim.clock.hour_of_day(), 20)
	assert_almost_eq(sim.grid.system_demand_kw, 801.7, 1.5,
			"the whole demand chain: catalog base_kw × channels × sinks")
	# Nameplate check at channel ≈ 1.0 is doc 09's 402.0 building figure;
	# verify the street/signal split exactly.
	var ctx_sinks := 0.0
	for node in sim.loader.power.get("nodes", []):
		if String(node["kind"]) == "transformer":
			ctx_sinks += float(node.get("streetlights", 0)) * 0.35 + float(node.get("signals", 0)) * 0.6
	assert_almost_eq(ctx_sinks, 274.05 + 48.60, 0.01)


func test_f_south_darkens_exactly_its_subtree() -> void:
	# Milestone 1 acceptance criterion 6.
	var sim := CitySim.boot_from_files()
	sim.advance_hours(1.0)
	assert_true(sim.grid.is_energized("F_SOUTH") and sim.grid.is_energized("F_NORTH"))
	var south_transformers: Array = []
	var north_transformers: Array = []
	for node in sim.loader.power.get("nodes", []):
		if String(node["kind"]) != "transformer":
			continue
		if String(node["feeder"]) == "F_SOUTH":
			south_transformers.append(String(node["id"]))
		else:
			north_transformers.append(String(node["id"]))
	sim.grid.force_open("F_SOUTH")
	sim.advance_hours(0.25)
	for id in south_transformers:
		assert_false(sim.grid.is_energized(id), "%s must be dark" % id)
	for id in north_transformers:
		assert_true(sim.grid.is_energized(id), "%s must stay lit" % id)
	# Buildings served by F_SOUTH report DARK after the hysteresis window;
	# their blocks flag block_dark.
	var weights := {}
	for id in sim.buildings.keys():
		var b: Building = sim.buildings[id]
		weights[id] = int(b.stats.get("population", 0)) + int(b.stats.get("jobs", 0))
	var blocks := sim.grid.block_dark_fractions(weights)
	var any_dark := false
	for block_id in blocks:
		if bool(blocks[block_id]["dark"]):
			any_dark = true
	assert_true(any_dark, "at least one southern block flags block_dark")
	# District stability degrades on the 6-gh reliability EMA: after three
	# game-hours the worst district must have visibly dropped (doc 09's
	# F_SOUTH scenario is quoted at the 3 gh mark).
	var before := 1.0
	for district_id in sim.districts.district_ids_sorted():
		before = minf(before, float(sim.districts.district(district_id)["stability"]))
	sim.advance_hours(3.0)
	var lowest := 1.0
	for district_id in sim.districts.district_ids_sorted():
		lowest = minf(lowest, float(sim.districts.district(district_id)["stability"]))
	assert_true(lowest < before - 0.03,
			"the outage reaches the stability aggregate (%.3f → %.3f)" % [before, lowest])
	# Restore: everything relights.
	sim.grid.force_close("F_SOUTH")
	sim.advance_hours(0.25)
	for id in south_transformers:
		assert_true(sim.grid.is_energized(id))


func test_24_hours_deterministic() -> void:
	# Milestone 1 criteria 3, 4, 7 (sans economy): the same seed advanced 24
	# game-hours twice produces byte-identical state hashes.
	var a := CitySim.boot_from_files(4242)
	var b := CitySim.boot_from_files(4242)
	a.advance_hours(24.0)
	b.advance_hours(24.0)
	assert_eq(a.clock.day_index(), 1, "24 game-hours elapsed")
	assert_eq(a.state_hash(), b.state_hash(), "byte-identical after 5,760 ticks")
	# A different seed diverges (the hazard stream differs).
	var c := CitySim.boot_from_files(999)
	c.advance_hours(24.0)
	# (Hash MAY coincide if no stochastic event fired on either seed; assert
	# only the deterministic pair, and that the clock agrees.)
	assert_eq(c.clock.tick_index, a.clock.tick_index)


func test_economy_settles_in_the_loop() -> void:
	# Milestone 1 criterion 7: economy settles hourly; the founding ledger's
	# +$318.77/gh lands in the treasury through the LIVE input chain (real
	# grid inventory, real district stability, real occupancy).
	# As-integrated anchors (doc 93 §E2): doc 03's worked +$318.77/gh was computed
	# against the HELD water/road stubs. Docs 05/10 now bill live — water service
	# factors, real E_water inventory, per-building road access — and doc 06's
	# live fleet roster replaced doc 03's held `STARTER_VEHICLES` (doc 92 pass-2
	# fleet-billing ruling: E_fleet 58 → 76, E_fuel_vehicle 6 → 0). The founding
	# hour lands at ≈ +$336.50/gh, which is what `data/economy.json`'s re-stamped
	# `STARTER_NET_PER_HOUR_EXACT` says. The doc 03 §2.12 worked-example refresh
	# is tracked in doc 93; the LIVE CHAIN is the test, and
	# `tests/test_balance_gates.gd` gates 1–2 hold the exact figures.
	var sim := CitySim.boot_from_files()
	var start: int = sim.treasury.balance
	sim.advance_hours(1.0)
	var first_hour: int = sim.treasury.balance - start
	assert_true(first_hour >= 330 and first_hour <= 343,
			"first settled hour ≈ +$336.50 (got %d)" % first_hour)
	# **RE-FIT Wave 14 (doc 92 §33.2, report 98 RR-69): ≈ +$8,006 → ≈ +$7,390.**
	# The FIRST HOUR above did not move (it is clear weather, and the band holds
	# with three times the margin to spare) — the DAY did, because doc 07's
	# weather state now reaches doc 10's roads and the founding day at seed 1337
	# rains for twelve of its twenty-four game-hours. `wx_wear_day` steps
	# 0.00 → 0.30 at gh 13 and holds (it is the day's MAX), so `E_roads_repair`'s
	# `(1 + 0.75·c_day)·(1 + wx_wear_day)` averages 1.2493 over the day against
	# 1.0857 in permanent sunshine, and the line goes $158.42 → $183.92/gh.
	# Every other expense line and the whole revenue side are unchanged to the
	# cent — doc 92 §33.2 carries the eight-line table and the hour-by-hour
	# derivation. Same ±2.5 % band this assertion always had, re-centred.
	sim.advance_hours(23.0)
	var day_net: int = sim.treasury.balance - start
	assert_true(day_net >= 7_200 and day_net <= 7_580,
			"a founding day nets ≈ +$7,390 in the founding day's real weather (got %d)"
					% day_net)


func test_availability_settles_hourly() -> void:
	var sim := CitySim.boot_from_files()
	sim.advance_hours(2.0)
	# Fully served city: every building reports availability 1.0.
	for id in sim.buildings.keys():
		if (sim.buildings[id] as Building).archetype == &"substation":
			continue
		assert_almost_eq(sim.grid.power_availability_hour(id), 1.0, 1e-6)
	# Population and happiness rolled up without drama at t0 levels.
	assert_eq(sim.population.city_population, 144, "doc 09 §2.10 worked value")
	assert_true(sim.happiness.happiness > 78.0 and sim.happiness.happiness < 86.0)
	assert_true(sim.districts.city_stability > 0.90)


func test_tutorial_tags_resolve() -> void:
	var sim := CitySim.boot_from_files()
	assert_false(sim.loader.resolve_tag("tutorial_transformer").is_empty())
	assert_false(sim.loader.resolve_tag("tutorial_land_block").is_empty())
	assert_false(sim.loader.resolve_tag("tutorial_pump").is_empty())


## Doc 02 §2.6's last dead path, wired (Wave 4): a `damaged` building below
## condition 0.10 collapses at 0.02/gh on the `failures` stream, from the same
## hourly loop that already ran `apply_decay`.
func test_structural_failure_is_wired_to_the_hourly_loop() -> void:
	var sim := CitySim.boot_from_files(4242)
	var target := ""
	for id in sim.buildings:
		var b: Building = sim.buildings[id]
		if b.state == &"active" and b.decays():
			target = String(id)
			break
	assert_ne(target, "", "the founding manifest has something that decays")
	var doomed: Building = sim.buildings[target]
	doomed.state = &"damaged"
	doomed.condition = 0.05
	sim.bus.drain()
	var destroyed := {}
	for _h in 400:
		sim.advance_coarse_hours(1, false)
		for event in sim.bus.drain():
			if event["type"] == &"building_destroyed":
				destroyed[String(event.get("sim_id", ""))] = String(event.get("cause", ""))
		if doomed.state == &"destroyed":
			break
	assert_eq(String(doomed.state), "destroyed",
			"0.02/gh never fired in 400 game-hours — the roll has no caller again")
	assert_eq(String(destroyed.get(target, "")), "structural_failure",
			"doc 02's own event, with its own cause, reaches the bus")
	# A destroyed building houses nobody: doc 09 reads STATE_OCCUPANCY 0.
	assert_almost_eq(doomed.state_occupancy(), 0.0, 1e-9)


## Doc 08 C-47: an absence may not silently demolish the city. The roll is not
## TAKEN during catch-up, so the rot is still standing when the player returns.
func test_structural_failure_is_refused_during_catchup() -> void:
	var sim := CitySim.boot_from_files(4242)
	var target := ""
	for id in sim.buildings:
		var b: Building = sim.buildings[id]
		if b.state == &"active" and b.decays():
			target = String(id)
			break
	var doomed: Building = sim.buildings[target]
	doomed.state = &"damaged"
	doomed.condition = 0.05
	sim.advance_coarse_hours(400, true)
	assert_ne(String(doomed.state), "destroyed",
			"offline catch-up destroyed a building behind the player's back")
	assert_true(doomed.condition < 0.05, "and it still decayed while they were away")


## Doc 12 §2.17 / doc 07: the tutorial holds the Director's floor, through
## `CitySim`, and the hold survives a save round trip like every other gate.
func test_director_suppression_api_for_the_tutorial() -> void:
	var sim := CitySim.boot_from_files()
	assert_false(sim.director.scripted_suppression_active())
	sim.suppress_director(3600.0)  # one game-hour of game-seconds
	assert_true(sim.director.scripted_suppression_active())
	assert_true(bool(sim.director.get_debug_state()["scripted_suppressed"]))
	# Calls EXTEND, never shorten: overlapping tutorial steps cannot uncover.
	sim.suppress_director(7200.0)
	var far := sim.director.suppress_until_min
	sim.suppress_director(60.0)
	assert_eq(sim.director.suppress_until_min, far)
	# It is not F5's earned suppression, and it does not claim to be.
	assert_false(bool(sim.director.suppression["active"]))
	var restored := CitySim.boot_from_files()
	restored.director.deserialize(sim.director.serialize())
	assert_eq(restored.director.suppress_until_min, sim.director.suppress_until_min)
	sim.release_director()
	assert_false(sim.director.scripted_suppression_active())
	assert_eq(sim.director.suppress_until_min, -1)


func test_block_dark_events_drive_the_renderer_contract() -> void:
	# The sim emits BlockDarkChanged on transitions (report 98 C-38) — the
	# render model's blackout ceremony consumes exactly this event.
	var sim := CitySim.boot_from_files()
	sim.advance_hours(1.0)
	sim.bus.drain()
	sim.grid.force_open("F_SOUTH")
	sim.advance_hours(0.1)  # > hysteresis window
	var dark_events: Array = []
	for event in sim.bus.drain():
		if event["type"] == &"BlockDarkChanged" and bool(event["block_dark"]):
			dark_events.append(event)
	assert_true(dark_events.size() >= 1, "southern blocks report dark")
	for event in dark_events:
		assert_almost_eq(float(event["powered_fraction"]), 0.0, 1e-9)
	# Restore: the same channel carries the relight.
	sim.grid.force_close("F_SOUTH")
	sim.advance_hours(0.1)
	var relit := 0
	for event in sim.bus.drain():
		if event["type"] == &"BlockDarkChanged" and not bool(event["block_dark"]):
			relit += 1
	assert_true(relit >= 1, "relight arrives on the same event channel")


# ------------------------------- doc 10 §5.1: the two seams nothing used to fill

func test_the_roads_land_use_and_weather_seams_are_injected() -> void:
	# `RoadNetwork.profile_weights_of` and `weather_state_of` shipped as fields
	# nothing assigned, so doc 09's per-district land-use weights and doc 10 §8's
	# weather rows were authored and unreachable. Both are wired now, and the
	# assertions below are what "wired" has to mean rather than a valid Callable.
	var sim := CitySim.boot_from_files()
	assert_true(sim.roads.profile_weights_of.is_valid(), "doc 09's weights reach roads")
	assert_true(sim.roads.weather_state_of.is_valid(), "doc 07's state reaches roads")
	assert_eq(sim.roads._weather_state(), sim.weather.get_state().to_lower(),
			"and roads reads the CITY-WIDE state, lower-cased onto its own table")

	# Report 98 RR-61's founding-city defect stays fixed: every sibling is
	# injected BEFORE `bootstrap()`, so `_assign_districts` had a valid Callable
	# on the pass that stamped the edges. With the weights live, an unstamped
	# edge is now a live-vs-restored divergence rather than an inert one.
	var blank := 0
	for edge_id in sim.roads.graph.edge_ids_sorted():
		if String(sim.roads.graph.edge(edge_id).get("district_id", "")) == "":
			blank += 1
	assert_eq(blank, 0, "every edge of a LIVE founding city carries its district")

	# The point of the table: districts disagree about the shape of their day.
	var rows: Dictionary = {}
	for district_id in sim.districts.district_ids_sorted():
		var weights: Dictionary = sim.roads.profile_weights_of.call(district_id)
		assert_false(weights.is_empty(), "%s publishes a land-use mix" % district_id)
		rows[district_id] = sim.roads.congestion.d_tod(weights, 2.5)
	var values: Array = rows.values()
	values.sort()
	assert_true(float(values[-1]) - float(values[0]) > 0.05,
			("the four founding districts want different amounts of road at 02:30 "
					+ "(%s) — before this wave every one of them read the default row")
					% str(rows))


func test_the_land_use_weights_survive_a_restore_identically() -> void:
	# They are DERIVED and not persisted, so the only thing that keeps a loaded
	# city on the live city's congestion is that the derivation is re-run from a
	# roster the save does carry. If it were not, save->load->advance would
	# diverge on the first congestion pass.
	var sim := CitySim.boot_from_files()
	sim.advance_hours(3.0)
	var before: Dictionary = {}
	for district_id in sim.districts.district_ids_sorted():
		before[district_id] = (sim.roads.profile_weights_of.call(district_id) as Dictionary) \
				.duplicate()
	var body := sim.capture_state()
	var restored := CitySim.boot_from_files()
	restored.restore_state(body)
	for district_id in restored.districts.district_ids_sorted():
		var weights: Dictionary = restored.roads.profile_weights_of.call(district_id)
		var was: Dictionary = before[district_id]
		for profile in DistrictRegistry.PROFILES:
			assert_eq(float(weights[profile]), float(was[profile]),
					"%s.%s is the same float after a restore" % [district_id, profile])
