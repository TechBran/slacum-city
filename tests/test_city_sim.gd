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
	assert_eq(sim.grid.grid_inventory()["nodes"].size(), 24, "substation + 23 transformers")
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
	# As-integrated anchors (doc 93): doc 03's worked +$318.77/gh was computed
	# against the HELD water/road stubs. Docs 05/10 now bill live — water
	# service factors, real E_water inventory, per-building road access — and
	# the founding hour lands at ≈ +$345/gh, ≈ +$8.3k/day. The doc 03 §2.12
	# worked-example refresh is tracked in doc 93; the LIVE CHAIN is the test.
	var sim := CitySim.boot_from_files()
	var start: int = sim.treasury.balance
	sim.advance_hours(1.0)
	var first_hour: int = sim.treasury.balance - start
	assert_true(first_hour >= 338 and first_hour <= 352,
			"first settled hour ≈ +$345 (got %d)" % first_hour)
	sim.advance_hours(23.0)
	var day_net: int = sim.treasury.balance - start
	assert_true(day_net >= 8_150 and day_net <= 8_550,
			"a founding day nets ≈ +$8,350 (got %d)" % day_net)


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
