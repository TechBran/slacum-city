extends SimTest
## Doc 09 §2.10–2.12: population aggregates, occupancy, attractiveness
## relaxation, happiness, city level and stats — against the doc's worked values.


static func starter_buildings() -> Array:
	var buildings: Array = []
	for i in 18:
		buildings.append({"id": "H-%03d" % i, "population": 4, "jobs": 0,
				"residential": true, "civic": false, "state_occupancy": 1.0, "age_hours": 48.0})
	for i in 3:
		buildings.append({"id": "A-%03d" % i, "population": 24, "jobs": 2,
				"residential": true, "civic": false, "state_occupancy": 1.0, "age_hours": 48.0})
	for i in 5:
		buildings.append({"id": "S-%03d" % i, "population": 0, "jobs": 6,
				"residential": false, "civic": false, "state_occupancy": 1.0, "age_hours": 48.0})
	buildings.append({"id": "O-001", "population": 0, "jobs": 30,
			"residential": false, "civic": false, "state_occupancy": 1.0, "age_hours": 48.0})
	buildings.append({"id": "POL-1", "population": 0, "jobs": 40,
			"residential": false, "civic": true, "state_occupancy": 1.0, "age_hours": 48.0})
	return buildings


func test_t0_aggregates_worked_values() -> void:
	var pop := PopulationSystem.new()
	var result := pop.advance(starter_buildings(), 0.001, 0.9475)
	# Doc 09 §2.10.2 worked at t0.
	assert_almost_eq(float(result["occupied_population"]), 144.0, 0.01)
	assert_eq(int(result["city_population"]), 144)
	assert_almost_eq(float(result["workforce"]), 79.2, 0.01)
	assert_eq(int(result["jobs_market"]), 66, "5×6 + 30 + 3×2; civic excluded")
	assert_eq(int(result["jobs_capacity"]), 106)
	assert_almost_eq(float(result["job_fill_city"]), 1.0, 1e-9)
	assert_almost_eq(pop.occ_of("S-000"), 1.0, 1e-9)
	assert_almost_eq(pop.occ_of("POL-1"), 1.0, 1e-9, "civic always fully staffed")
	assert_almost_eq(pop.employment_balance(), 0.8333, 0.0005)


func test_ramp() -> void:
	assert_almost_eq(PopulationSystem.ramp(0.0), 0.35, 1e-9)
	assert_almost_eq(PopulationSystem.ramp(18.0), 0.675, 1e-9)
	assert_almost_eq(PopulationSystem.ramp(36.0), 1.0, 1e-9)
	assert_almost_eq(PopulationSystem.ramp(100.0), 1.0, 1e-9)


func test_attractiveness_target_clamps() -> void:
	assert_almost_eq(PopulationSystem.attractiveness_target(0.9475), 1.0, 1e-9, "saturated ≥0.85")
	assert_almost_eq(PopulationSystem.attractiveness_target(0.60), 0.50, 1e-9)
	assert_almost_eq(PopulationSystem.attractiveness_target(0.10), 0.25, 1e-9, "floor")


func test_exodus_relaxation_worked_value() -> void:
	# Doc 09 §2.10.2: city_stability 0.60 for six hours → A_city 0.8033,
	# occupied 144 → 116.
	var pop := PopulationSystem.new()
	var result := pop.advance(starter_buildings(), 6.0, 0.60)
	assert_almost_eq(pop.attractiveness, 0.8033, 0.0005)
	assert_eq(int(result["city_population"]), 116)
	# Recovery is symmetric and slow: six good hours climb back the same curve.
	pop.advance(starter_buildings(), 6.0, 0.95)
	assert_almost_eq(pop.attractiveness, 0.8033 + (1.0 - 0.8033) * (1.0 - exp(-0.5)), 0.0005)


func test_tax_drag_slows_refill() -> void:
	var fast := PopulationSystem.new()
	fast.attractiveness = 0.5
	fast.advance(starter_buildings(), 6.0, 0.95, 1.0)
	var slow := PopulationSystem.new()
	slow.attractiveness = 0.5
	slow.advance(starter_buildings(), 6.0, 0.95, 0.755)  # 16% tax rate
	assert_true(slow.attractiveness < fast.attractiveness)


func test_serialize_sparse() -> void:
	var pop := PopulationSystem.new()
	pop.advance(starter_buildings(), 6.0, 0.60)  # everything below 1.0 now
	var data := pop.serialize()
	assert_true((data["occupancy"] as Dictionary).size() > 0)
	var pop2 := PopulationSystem.new()
	pop2.advance(starter_buildings(), 0.001, 0.9475)  # all at ~1.0
	assert_eq((pop2.serialize()["occupancy"] as Dictionary).size(), 0, "sparse: 1.00 not stored")


func test_happiness_worked_values() -> void:
	# Doc 09 §2.10.3 worked at t0: H_target ≈ 82.15.
	var target: float = HappinessModel.target(0.9475, 1.000, 0.8333, 1.000, 0.0)
	assert_almost_eq(target, 82.2, 0.15)
	var model := HappinessModel.new()
	assert_almost_eq(model.f_happiness(), 1.110, 0.001)
	# 3 gh into the F_SOUTH fault: H 82 → ~79.86, f_happiness ~1.099.
	model.advance(3.0, 0.9074, 0.9771, 0.8333, 1.000, 0.0)
	assert_almost_eq(model.happiness, 79.87, 0.1)
	assert_almost_eq(model.f_happiness(), 1.099, 0.001)


func test_happiness_band_and_tax_reach() -> void:
	# Band is [24, 96] before tax: only the tax slider reaches the clamps.
	assert_almost_eq(HappinessModel.target(0.0, 0.0, 0.0, 0.0, 0.0), 24.0, 1e-6)
	assert_almost_eq(HappinessModel.target(1.0, 1.0, 1.0, 1.0, 0.0), 96.0, 1e-6)
	var model := HappinessModel.new()
	model.happiness = 100.0
	assert_almost_eq(model.f_happiness(), 1.20, 1e-6)
	model.happiness = 0.0
	assert_almost_eq(model.f_happiness(), 0.75, 1e-6, "lower clamp engaged (raw would be 0.70)")


func test_city_level_ladder_and_monotonicity() -> void:
	assert_eq(ProgressionSystem.level_reached(144), 0)
	assert_eq(ProgressionSystem.level_reached(250), 1)
	assert_eq(ProgressionSystem.level_reached(999), 1)
	assert_eq(ProgressionSystem.level_reached(4000), 3)
	assert_eq(ProgressionSystem.level_reached(30000), 5)
	var progression := ProgressionSystem.new()
	var events := progression.update(1000)
	assert_eq(progression.city_level, 2)
	var types: Array = events.map(func(e: Dictionary) -> String: return String(e.get("id", e["type"])))
	assert_true(types.has("city_level_changed"))
	assert_true(types.has("city_level_1"))
	assert_true(types.has("city_level_2"))
	assert_true(types.has("population_1k"))
	# Disaster halves the city: the level is never lost, no events fire.
	assert_eq(progression.update(100).size(), 0)
	assert_eq(progression.city_level, 2)
	assert_eq(progression.next_level_threshold(), 4000)


func test_milestones_one_shot_and_roundtrip() -> void:
	var progression := ProgressionSystem.new()
	assert_eq(progression.grant("first_land_purchase").size(), 1)
	assert_eq(progression.grant("first_land_purchase").size(), 0, "one-shot")
	progression.update(300)
	var restored := ProgressionSystem.new()
	restored.deserialize(progression.serialize())
	assert_eq(restored.city_level, 1)
	assert_true(restored.has_milestone("first_land_purchase"))


func test_stats_counters() -> void:
	var stats := StatsRecorder.new()
	stats.add("blocks_purchased")
	stats.add("blocks_purchased")
	stats.add("outage_minutes_total", 45)
	stats.record_peak("peak_population", 144)
	stats.record_peak("peak_population", 120)  # lower — must not regress
	assert_eq(stats.get_counter("blocks_purchased"), 2)
	assert_eq(stats.get_counter("outage_minutes_total"), 45)
	assert_eq(stats.get_counter("peak_population"), 144)
	var restored := StatsRecorder.new()
	restored.deserialize(stats.serialize())
	assert_eq(restored.get_counter("peak_population"), 144)
	assert_eq(restored.get_counter("never_written"), 0)
