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


## Doc 09 §2.10.2a (amendment T-1): the ceiling is the most binding of three,
## and every pre-T-1 worked value survives because `A_stab` is untouched.
func test_attractiveness_target_composes_three_ceilings() -> void:
	# The founding city, at the base detent: all three are 1.00 and so is A.
	assert_almost_eq(PopulationSystem.attractiveness_target(0.9475, 82.0, 1.0), 1.0, 1e-9)
	# Each ceiling binds alone.
	assert_almost_eq(PopulationSystem.attractiveness_target(0.60, 100.0, 1.0), 0.50, 1e-9,
			"stability binds — the F_SOUTH exodus, unchanged by T-1")
	assert_almost_eq(PopulationSystem.attractiveness_target(0.9475, 40.0, 1.0),
			1.0 - 1.30 * 20.0 / 100.0, 1e-9, "happiness binds")
	assert_almost_eq(PopulationSystem.attractiveness_target(0.9475, 100.0, 0.6724), 0.6724, 1e-9,
			"the tax bill binds")
	# Above the reference, happiness cannot LIFT the ceiling past stability.
	assert_almost_eq(PopulationSystem.happiness_ceiling(96.0), 1.0, 1e-9)
	assert_almost_eq(PopulationSystem.attractiveness_target(0.60, 96.0, 1.0), 0.50, 1e-9)
	# The floor is shared, so no combination can empty the city completely.
	assert_almost_eq(PopulationSystem.attractiveness_target(0.0, 0.0, 0.0), 0.25, 1e-9)


## The no-double-count rule, as arithmetic: `min`, never a product. The tax bill
## is already a term of `H_target`, so multiplying the two channels would bill it
## twice. Both terms carry the same pull, so the crossover reads in one line:
## happiness takes over when `H` has fallen further below 60 than the tax bill
## itself — at the top detent, below `60 − 25.2 = 34.8` (Wave-7 coefficient; the
## crossover moves with `TAX_RATE_HAPPINESS_COEFF` and nothing else does).
func test_tax_and_happiness_ceilings_never_stack() -> void:
	const TOP_FACTOR := 0.6724  # attractiveness_tax_factor(0.16), coeff 360
	# An overtaxed but otherwise-fine city: the tax term binds, alone.
	assert_almost_eq(PopulationSystem.attractiveness_target(0.9475, 53.9, TOP_FACTOR),
			TOP_FACTOR, 1e-9, "H is 53.9 BECAUSE of the tax; it may not be charged again")
	# Push it past the crossover and the happiness term takes over — still once.
	# 40 was past it at coeff 220 and is not any more: the tax bill itself is now
	# harsher than a 20-point mood, which is the crossover moving, not a bug.
	assert_almost_eq(PopulationSystem.attractiveness_target(0.9475, 40.0, TOP_FACTOR),
			TOP_FACTOR, 1e-9, "40 is above the 34.8 crossover")
	var miserable := PopulationSystem.attractiveness_target(0.9475, 20.0, TOP_FACTOR)
	assert_almost_eq(miserable, PopulationSystem.happiness_ceiling(20.0), 1e-9)
	assert_true(miserable < TOP_FACTOR, "genuine misery is harsher than the tax bill")
	# And the product — what T-1 deliberately did NOT do. The gate-12b city
	# settles at H 53.9 with the same tax bill in force; `min` leaves the ceiling
	# at 0.6724, a product would push it to 0.619 for the same 25.2 points.
	assert_true(PopulationSystem.happiness_ceiling(53.9) * TOP_FACTOR < TOP_FACTOR - 0.02,
			"a product would double-bill the same discontent")


## Doc 03 publishes the tax term; doc 09 spends it. Neutral at and below base.
func test_attractiveness_tax_factor_detents() -> void:
	var economy := CitySim.boot_from_files().economy
	assert_almost_eq(economy.attractiveness_tax_factor(0.09), 1.0, 1e-9, "base detent")
	assert_almost_eq(economy.attractiveness_tax_factor(0.04), 1.0, 1e-9,
			"a tax CUT buys a faster refill, never a higher ceiling")
	assert_almost_eq(economy.attractiveness_tax_factor(0.16), 0.6724, 1e-9,
			"1 + 1.30 × (−25.2)/100")
	# The founding city may not move at the base detent — the anchor T-1 protects.
	var pop := PopulationSystem.new()
	pop.advance(starter_buildings(), 24.0, 0.9475, 1.0, 82.0,
			economy.attractiveness_tax_factor(0.09))
	assert_almost_eq(pop.attractiveness, 1.0, 1e-9)
	assert_eq(int(pop.advance(starter_buildings(), 0.001, 0.9475, 1.0, 82.0,
			1.0)["city_population"]), 144)
	# And at the top detent it walks down to 0.6724 — 144 people become 97.
	var squeezed := PopulationSystem.new()
	var result := {}
	for _h in 24 * 7:
		result = squeezed.advance(starter_buildings(), 1.0, 0.9475,
				economy.growth_rate_multiplier(0.16), 66.75,
				economy.attractiveness_tax_factor(0.16))
	assert_almost_eq(squeezed.attractiveness, 0.6724, 0.001)
	assert_eq(int(result["city_population"]), 97)
	assert_almost_eq(float(result["attractiveness_target"]), 0.6724, 1e-9)


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
	slow.advance(starter_buildings(), 6.0, 0.95, 0.44)  # 16% tax rate (coeff 8.0)
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


## The RULE, not the rungs. Doc 92 §19 retuned doc 09 §2.11's ladder and this
## test used to pin the old rungs as literals, so a legitimate retune read as
## three failures here and as nothing at all where it mattered. The numbers now
## live in `data/progression.json` and are gated — with their measured
## justification — by `tests/test_balance_gates.gd::test_gate_20_*`; what this
## test owns is the arithmetic that must hold for ANY ascending ladder.
func test_city_level_ladder_and_monotonicity() -> void:
	var ladder := ProgressionSystem.city_level_pop()
	assert_eq(ladder[0], 0)
	for level in ladder.size():
		# Exactly at a rung you are on it; one resident short you are below it.
		assert_eq(ProgressionSystem.level_reached(ladder[level]), level)
		if ladder[level] > 0:
			assert_eq(ProgressionSystem.level_reached(ladder[level] - 1), level - 1)
	var top := ladder[ladder.size() - 1]
	assert_eq(ProgressionSystem.level_reached(top * 10), ladder.size() - 1,
			"the top rung is the top: more people cannot make a seventh level")
	var progression := ProgressionSystem.new()
	# One update that crosses two rungs at once must grant BOTH milestones.
	var events := progression.update(ladder[2])
	assert_eq(progression.city_level, 2)
	var types: Array = events.map(func(e: Dictionary) -> String: return String(e.get("id", e["type"])))
	assert_true(types.has("city_level_changed"))
	assert_true(types.has("city_level_1"))
	assert_true(types.has("city_level_2"))
	# Disaster halves the city: the level is never lost, no events fire.
	assert_eq(progression.update(ladder[1] / 2).size(), 0)
	assert_eq(progression.city_level, 2)
	assert_eq(progression.next_level_threshold(), ladder[3])
	# Doc 09 §2.11's population milestones are named for their POPULATION and are
	# independent of the level ladder — they must not move when it is retuned.
	var pop_milestones := ProgressionSystem.new()
	var crossed: Array = pop_milestones.update(10000).map(
			func(e: Dictionary) -> String: return String(e.get("id", e["type"])))
	assert_true(crossed.has("population_1k"))
	assert_true(crossed.has("population_10k"))
	assert_false(ProgressionSystem.new().update(999).map(
			func(e: Dictionary) -> String: return String(e.get("id", e["type"])))
			.has("population_1k"))


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
