extends SimTest
## Doc 07 §2.7.3 — strike generation and target selection, and the seam into
## doc 04's ds0–ds3 damage bands. Tests 13–17 of §7.
##
## This subsystem selects; doc 04 resolves (report 98 C-54). Every assertion
## below is on one side of that line or the other, never across it.

const WEATHER_DATA := "res://data/weather.json"
const DIRECTOR_DATA := "res://data/director.json"


func _tables() -> DirectorTables:
	return DirectorTables.load_from_file(DIRECTOR_DATA)


func _targeter() -> LightningTargeter:
	return LightningTargeter.new(_tables().lightning())


func _target(ref: String, weight_class: String, height: float, condition: float,
		protections: Array = [], exposure: String = "outdoor",
		pos: Vector2 = Vector2.ZERO, f10: bool = false) -> Dictionary:
	return {"ref": ref, "domain": "grid", "weight_class": weight_class,
			"height_m": height, "condition": condition, "exposure": exposure,
			"protections": protections, "pos": pos, "f10_protected": f10}


func test_director_data_valid() -> void:
	var tables := _tables()
	assert_true(tables.is_valid(), "data/director.json valid: " + str(tables.errors))
	assert_eq(tables.events.size(), 8, "8 catalog events")
	assert_eq(int(tables.event_by_id("severe_thunderstorm")["hazard_tier"]), 3, "tier 3")
	assert_eq(int(tables.event_by_id("storm_minor")["hazard_tier"]), 1, "tier 1")


func test_14_lightning_weight_golden() -> void:
	# §2.7.3's worked comparison — the whole player-facing point of maintenance
	# and arrester spending is that it shows up here.
	var targeter := _targeter()
	var prepared := _target("s_prepared", "substation", 20.0, 0.90, ["arrester"])
	var unprepared := _target("s_unprepared", "substation", 20.0, 0.45)
	var w_prepared := targeter.weight_for(prepared, null, 0, {}, {}, {})
	var w_unprepared := targeter.weight_for(unprepared, null, 0, {}, {}, {})
	assert_almost_eq(w_prepared, 1.510, 1e-3, "prepared substation weight")
	assert_almost_eq(w_unprepared, 6.844, 1e-3, "unprepared substation weight")
	assert_almost_eq(w_unprepared / w_prepared, 4.53, 0.02,
			"the neglected substation is ~4.5× more likely to be struck")


func test_14a_weight_factors() -> void:
	var targeter := _targeter()
	assert_almost_eq(targeter.height_factor(20.0), 1.5, 1e-9, "1 + h/40")
	assert_almost_eq(targeter.condition_factor(0.45), 1.825, 1e-9, "1 + 1.5(1−c)")
	assert_almost_eq(targeter.exposure_factor("underground"), 0.05, 1e-9, "buried assets")
	assert_almost_eq(targeter.protection_factor(["arrester"]), 0.35, 1e-9, "one protection")
	assert_almost_eq(targeter.protection_factor(["arrester", "surge_protection"]), 0.2, 1e-9,
			"the product floors at 0.20")
	assert_almost_eq(targeter.roll_energy(0.0), 0.6, 1e-9, "energy floor")
	assert_almost_eq(targeter.roll_energy(1.0), 1.6, 1e-9, "energy ceiling")
	assert_almost_eq(targeter.roll_energy(0.5), 1.1, 1e-9, "mean energy 1.10")


func test_16_immunity_weighting() -> void:
	# F4: hit <24 h → weight 0.00; hit <3 game-days → ×0.15; already struck this
	# storm → 0.00. These are the exact factors, not an approximation.
	var struck := {"a": true}
	assert_almost_eq(LightningTargeter.immunity_factor("a", 100, struck, {}, {}), 0.0, 1e-9,
			"already struck this storm")
	assert_almost_eq(LightningTargeter.immunity_factor("b", 100, {}, {"b": 1440}, {}), 0.0, 1e-9,
			"hard exclusion inside 24 h")
	assert_almost_eq(LightningTargeter.immunity_factor("c", 100, {}, {}, {"c": 4320}), 0.15, 1e-9,
			"soft immunity inside 3 game-days")
	assert_almost_eq(LightningTargeter.immunity_factor("d", 100, {}, {}, {}), 1.0, 1e-9,
			"no history")
	# And the selection actually honours it, over a real sample.
	var targeter := _targeter()
	var targets := [
		_target("immune", "substation", 20.0, 0.90),
		_target("normal", "substation", 20.0, 0.90),
	]
	var immune_picks := 0
	for i in 5000:
		var pick := targeter.select(targets, null, 100, {}, {}, {"immune": 4320},
				float(i) / 5000.0)
		if String(pick.get("ref", "")) == "immune":
			immune_picks += 1
	var share := float(immune_picks) / 5000.0
	assert_true(share <= 0.20, "immune share %f ≤ 0.20 of the un-immune baseline" % share)
	assert_true(share > 0.05, "immune targets are still reachable (%f)" % share)


func test_cell_gates_eligibility() -> void:
	# C-59: the cell is the only spatial object, and it gates ELIGIBILITY only.
	var targeter := _targeter()
	var cell := StormCell.new()
	cell.spawn(Vector2(100, 100), 50.0, WeatherTables.load_from_file(WEATHER_DATA), 7)
	cell.x_t = 100.0
	cell.z_t = 100.0
	var inside := _target("in", "substation", 20.0, 1.0, [], "outdoor", Vector2(110, 100))
	var outside := _target("out", "substation", 20.0, 1.0, [], "outdoor", Vector2(900, 900))
	assert_true(targeter.weight_for(inside, cell, 0, {}, {}, {}) > 0.0, "inside the cell")
	assert_almost_eq(targeter.weight_for(outside, cell, 0, {}, {}, {}), 0.0, 1e-9,
			"outside the cell is ineligible")
	assert_eq(targeter.select([outside], cell, 0, {}, {}, {}, 0.5).size(), 0,
			"no legal target → ground strike, never a forced hit")


# ------------------------------------------------------------ strike pacing

func _storm(intensity: float = 0.77, duration: int = 110, phase: float = 0.0) -> SevereThunderstorm:
	var storm := SevereThunderstorm.new(_tables())
	storm.begin(4242, 1.00, intensity, 0, duration, 8, phase)
	return storm


func test_2_7_3_strike_rate() -> void:
	# §2.7.3: 6.0 base × 0.77 intensity × severity 1.00. Peak hour 4.62 attempts,
	# trailing 50 min ×0.35 → 1.35. Total ≈ 5.967 per storm.
	var storm := _storm()
	assert_almost_eq(storm.phase_mult(SevereThunderstorm.PHASE_PEAK), 1.0, 1e-9)
	assert_almost_eq(storm.phase_mult(SevereThunderstorm.PHASE_TRAILING), 0.35, 1e-9)
	assert_almost_eq(storm.phase_mult(SevereThunderstorm.PHASE_LEAD_IN), 0.0, 1e-9,
			"lead-in is cosmetic only: no asset strike before the first flash")
	assert_eq(String(storm.phase_at(-25)), "idle")
	assert_eq(String(storm.phase_at(-15)), "lead_in")
	assert_eq(String(storm.phase_at(0)), "peak")
	assert_eq(String(storm.phase_at(59)), "peak")
	assert_eq(String(storm.phase_at(60)), "trailing")
	assert_eq(String(storm.phase_at(110)), "ended")


func test_14c_attempts_and_asset_strikes_converge_on_the_doc() -> void:
	# Mean attempts 5.967, of which 55% are asset strikes → 3.28 (§2.7.3).
	var targets: Array = []
	for i in 12:
		targets.append(_target("g_%02d" % i, "substation", 20.0, 0.80, [],
				"outdoor", Vector2(0, 0)))
	var rng := RngStreams.new(20260818)
	var total_attempts := 0
	var total_strikes := 0
	var storms := 400
	for s in storms:
		var storm := SevereThunderstorm.new(_tables())
		storm.begin(s, 1.00, 0.77, 0, 110, 8, rng.stream("weather").randf())
		for minute in range(-25, 111):
			storm.tick(minute, 1.0, rng, targets, null)
		total_attempts += int(storm.metrics["attempts"])
		total_strikes += int(storm.metrics["strikes"])
	var mean_attempts := float(total_attempts) / float(storms)
	var mean_strikes := float(total_strikes) / float(storms)
	assert_true(absf(mean_attempts - 5.967) < 0.12,
			"mean attempts %f ≈ 5.967" % mean_attempts)
	assert_true(absf(mean_strikes - 3.28) < 0.20, "mean asset strikes %f ≈ 3.28" % mean_strikes)


func test_15_no_double_strike_within_one_storm() -> void:
	var targets: Array = []
	for i in 6:
		targets.append(_target("g_%d" % i, "substation", 20.0, 0.50))
	var rng := RngStreams.new(31337)
	for s in 100:
		var storm := SevereThunderstorm.new(_tables())
		storm.begin(s, 1.40, 1.00, 0, 180, 8, rng.stream("weather").randf())
		var seen := {}
		for minute in range(-25, 181):
			for strike in storm.tick(minute, 1.0, rng, targets, null):
				var ref := String(strike["target_ref"])
				assert_false(seen.has(ref), "%s struck twice in one storm" % ref)
				seen[ref] = true
		assert_eq(storm.serialize()["struck_ids"].size(), seen.size(), "struck set persists")


func test_14b_strike_payload_shape() -> void:
	var targets := [
		_target("prot", "substation", 20.0, 0.50, [], "outdoor", Vector2.ZERO, true),
		_target("plain", "distribution_transformer", 10.0, 0.50),
	]
	var rng := RngStreams.new(2024)
	var payloads := 0
	for s in 300:
		var storm := SevereThunderstorm.new(_tables())
		storm.begin(s, 1.40, 1.00, 0, 180, 8, rng.stream("weather").randf())
		for minute in range(0, 181):
			for strike in storm.tick(minute, 1.0, rng, targets, null):
				payloads += 1
				for key in ["target_ref", "energy", "event_uid", "condition_floor"]:
					assert_true(strike.has(key), "LightningStrike carries %s" % key)
				var energy := float(strike["energy"])
				assert_true(energy >= 0.60 and energy <= 1.60, "energy ∈ [0.60, 1.60]")
				var expected_floor := 0.10 if String(strike["target_ref"]) == "prot" else 0.0
				assert_almost_eq(float(strike["condition_floor"]), expected_floor, 1e-9,
						"condition_floor == 0.10 iff F10-protected")
				assert_eq(int(strike["event_uid"]), s, "attribution for the storm report")
				assert_true(strike.has("world_pos"), "doc 11 §5 gets world_pos")
				assert_true(strike["world_pos"] is Vector3, "world_pos is a Vector3 in metres")
	assert_true(payloads > 200, "generated %d strikes" % payloads)


func test_ground_strikes_and_cosmetic_flashes() -> void:
	var storm := _storm(1.0, 180)
	var rng := RngStreams.new(5)
	var cosmetic := 0
	for minute in range(-25, 0):
		storm.tick(minute, 1.0, rng, [], null)
	for event in storm.drain_events():
		if event["type"] == &"lightning_flash_cosmetic":
			cosmetic += 1
	assert_true(cosmetic > 0, "the lead-in delivers flashes before any damage (%d)" % cosmetic)
	assert_eq(int(storm.metrics["strikes"]), 0, "zero asset strikes before T=0")
	# With no eligible targets every attempt lands as a ground strike.
	for minute in range(0, 120):
		storm.tick(minute, 1.0, rng, [], null)
	assert_true(int(storm.metrics["ground_strikes"]) > 0, "ground strikes happen")
	assert_eq(int(storm.metrics["asset_hits"]), 0, "no assets, no asset hits")


# ---------------------------------------------------- the doc 04 seam (C-54)

func test_grid_roster_from_starter_city() -> void:
	var sim := CitySim.boot_from_files(1337)
	assert_true(sim.boot_errors.is_empty(), "starter city boots")
	var roster := GridStrikeAdapter.roster(sim.grid)
	assert_true(roster.size() >= 4, "starter city exposes %d strike targets" % roster.size())
	var refs: Array = []
	for target in roster:
		refs.append(String(target["ref"]))
		assert_true(target.has("weight_class") and target.has("pos"), "descriptor complete")
		assert_true(float(target["condition"]) >= 0.0, "condition read from doc 04")
	var sorted_refs := refs.duplicate()
	sorted_refs.sort()
	assert_eq(refs, sorted_refs, "roster order is deterministic (sorted by id)")
	# The sole plant and the sole substation are F10-protected.
	var protected := 0
	for target in roster:
		if bool(target["f10_protected"]):
			protected += 1
	assert_true(protected >= 1, "the last plant/substation is irreplaceable (F10)")


func test_lightning_damage_arc_on_the_starter_city() -> void:
	# The end-to-end arc: storm → strike → doc 04's bands → grid events.
	var sim := CitySim.boot_from_files(4242)
	sim.advance_hours(1.0)
	sim.grid.drain_events()
	var roster := GridStrikeAdapter.roster(sim.grid)
	var storm := SevereThunderstorm.new(_tables())
	storm.begin(9001, 1.40, 1.00, 0, 180, 8, 0.5)
	var resolved := 0
	var bands := {}
	for minute in range(0, 181):
		for strike in storm.tick(minute, 1.0, sim.rng, roster, null):
			var result := GridStrikeAdapter.resolve(sim.grid, strike, sim.rng)
			resolved += 1
			bands[String(result["band"])] = int(bands.get(String(result["band"]), 0)) + 1
	assert_true(resolved > 0, "the storm struck %d grid assets" % resolved)
	var events := sim.grid.drain_events()
	var kinds := {}
	for event in events:
		kinds[String(event["type"])] = int(kinds.get(String(event["type"]), 0)) + 1
	assert_true(kinds.size() > 0, "doc 04 emitted its own events: " + str(kinds))
	# Every band that occurred is one of doc 04's — this doc invented none.
	for band in bands:
		assert_true(["ds0", "ds1", "ds2", "ds3"].has(String(band)),
				"band %s is doc 04's" % band)


func test_17_f10_condition_floor_is_enforced() -> void:
	# 1 000 forced resolutions against a single-plant city: never below 0.10,
	# never destroyed, always repairable.
	var grid := PowerGrid.new()
	grid.add_component("plant", &"plant_gas", {"level": 3, "condition": 0.5})
	grid.add_component("s_1", &"substation", {"level": 3, "condition": 0.5})
	var rng := RngStreams.new(77)
	var roster := GridStrikeAdapter.roster(grid)
	var protected_refs := {}
	for target in roster:
		if bool(target["f10_protected"]):
			protected_refs[String(target["ref"])] = true
	assert_eq(protected_refs.size(), 2, "one plant and one substation are both last-of-kind")
	for i in 1000:
		var ref := "plant" if i % 2 == 0 else "s_1"
		GridStrikeAdapter.resolve(grid, {"target_ref": ref, "energy": 1.6,
				"event_uid": 1, "condition_floor": 0.10}, rng)
		assert_true(float(grid.component(ref)["condition"]) >= 0.10 - 1e-9,
				"%s never falls below the F10 floor" % ref)
		assert_ne(String(grid.component(ref).get("failed_cause", "")), "LIGHTNING_DESTROYED",
				"F10 converts destruction into a repairable failure")
		grid.repair_component(ref)
	assert_false(grid.component("plant").is_empty(), "the last plant still exists")


func test_grid_damage_probability_matches_doc_04() -> void:
	# The strike→failure conversion of §2.7.3, measured against doc 04's own
	# resolver: p_damage = 0.55 · (1 − 0.22·arrester) · E[energy 1.10].
	var grid := PowerGrid.new()
	grid.add_component("bare", &"substation", {"level": 3, "condition": 1.0})
	grid.add_component("armed", &"substation", {"level": 3, "condition": 1.0,
			"arrester_level": 1})
	var rng := RngStreams.new(909)
	var targeter := _targeter()
	var damaged := {"bare": 0, "armed": 0}
	var trials := 4000
	for i in trials:
		for ref in ["bare", "armed"]:
			var energy := targeter.roll_energy(rng.stream("weather").randf())
			var result := grid.resolve_lightning(ref, energy, rng)
			if String(result["band"]) != "ds0":
				damaged[ref] = int(damaged[ref]) + 1
			grid.repair_component(ref)
	var p_bare := float(damaged["bare"]) / float(trials)
	var p_armed := float(damaged["armed"]) / float(trials)
	assert_true(absf(p_bare - 0.605) < 0.03, "no arrester: %f ≈ 0.605" % p_bare)
	assert_true(absf(p_armed - 0.472) < 0.03, "arrester L1: %f ≈ 0.472" % p_armed)
	assert_true(p_armed < p_bare, "an arrester buys back ~22% of grid failures")


func test_choreography_caps() -> void:
	# §2.7.5: rolls over the cap are DOWNGRADED, never deleted.
	var storm := SevereThunderstorm.new(_tables())
	storm.begin(1, 1.0, 0.8, 0, 120, 8)
	assert_eq(storm.max_concurrent(), 12, "3 + 1.1 × 8 units")
	assert_eq(storm.max_new_per_10min(), 4, "max(2, ceil(8 × 0.5))")
	var sink := IncidentRequestSink.Recording.new()
	var accepted := 0
	for i in 40:
		if storm.request_incident(sink, 5, &"storm_damage", {"ref": "x_%d" % i}):
			accepted += 1
	assert_eq(accepted, 4, "the 10-minute cap binds")
	assert_eq(sink.requests.size(), 4, "doc 06 saw exactly the accepted requests")
	assert_eq(int(storm.metrics["downgraded"]), 36, "the rest are downgraded, not deleted")
	var downgrades := 0
	for event in storm.drain_events():
		if event["type"] == &"storm_incident_downgraded":
			downgrades += 1
			assert_almost_eq(float(event["condition_delta"]), -0.03, 1e-9,
					"the player still pays: a condition ding")
	assert_eq(downgrades, 36, "every downgrade is logged for the storm report")


func test_storm_report_and_storm_ready() -> void:
	var storm := SevereThunderstorm.new(_tables())
	storm.begin(77, 1.0, 0.77, 0, 120, 8, 0.5)
	var targets := [_target("s_bad", "substation", 20.0, 0.35),
			_target("s_ok", "substation", 20.0, 0.95)]
	var rng := RngStreams.new(3)
	for minute in range(0, 121):
		storm.tick(minute, 1.0, rng, targets, null)
	var report := storm.build_report(1030)
	assert_eq(int(report["event_uid"]), 77)
	assert_eq(int(report["repair_cost"]), 1030,
			"the report READS BACK doc 03's ledger total (C-16), it prices nothing")
	assert_true((report["root_causes"] as Array).size() > 0, "root causes are named")
	for cause in report["root_causes"]:
		assert_ne(String(cause["reason"]), "", "every root cause has a reason code")
	# Storm Ready needs BOTH conditions (§2.7.6).
	storm.prep_actions = ["pre_stage_crews", "load_shed", "top_off_water"]
	storm.metrics["outage_customer_minutes"] = 11200
	assert_true(storm.storm_ready_earned(45000), "3 preps and 11 200 < 11 250 → awarded")
	storm.metrics["outage_customer_minutes"] = 11300
	assert_false(storm.storm_ready_earned(45000), "just over the threshold → not awarded")
	storm.prep_actions = ["load_shed"]
	storm.metrics["outage_customer_minutes"] = 100
	assert_false(storm.storm_ready_earned(45000), "fewer than 3 preps → not awarded")
