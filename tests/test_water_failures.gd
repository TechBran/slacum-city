extends SimTest
## Doc 05 §7 tests 17–19, 21–22 and 27 — the failure model, the multipliers
## published to doc 06 (C-46), repair work content, `damage_fraction` (C-16),
## the contamination stub, and the save round-trip.
##
## Doc 06 owns the `water_main_break` ROLL; this doc owns the three
## dimensionless multipliers doc 06 multiplies into it, which is why the
## calibration of `FREEZE_HAZARD_GAIN = 2.5` is asserted here against doc 06's
## own rate expression rather than against a number this doc rolls itself.

const DT := 1.0 / 240.0
const H13 := {"water_demand_residential": 1.075, "water_demand_commercial": 1.65}
const DOC06_R_WM_BASE := 0.0022  # doc 06's per-km-hour main-break base


func _data() -> WaterData:
	return WaterData.from_dict(StarterCityLoader.read_json("res://data/water.json"))


func _rig(opts: Dictionary = {}) -> WaterSystem:
	var system := WaterSystem.new(WaterData.from_dict(
			StarterCityLoader.read_json("res://data/water.json")), 64)
	system.add_node("SRC", &"source", Vector2i(10, 10),
			{"subtype": "river", "level": 2, "power_ref": "WTR"})
	system.add_node("TRT", &"treatment", Vector2i(10, 10), {"level": 2, "power_ref": "WTR"})
	system.add_node("PMP", &"pump", Vector2i(10, 10),
			{"level": int(opts.get("pump_level", 1)),
			"condition": float(opts.get("pump_condition", 1.0)), "power_ref": "WTR"})
	if not bool(opts.get("no_tank", false)):
		system.add_node("TNK", &"tank", Vector2i(10, 14), {"power_ref": "WTR-TANK"})
	system.add_main("M1", [Vector2i(10, 10), Vector2i(10, 14)], {"tier": "trunk"})
	system.attach_building("H0", Vector2i(11, 12), "house")
	system.attach_building("S0", Vector2i(11, 13), "store")
	system.set_demands({"H0": float(opts.get("house_demand", 8.0)), "S0": 4.0})
	return system


func _run_hours(system: WaterSystem, rng: RngStreams, hours: int, coarse: bool) -> Array:
	var log: Array = []
	for h in hours:
		if coarse:
			system.advance(1.0, H13)
		else:
			for i in 240:
				system.advance(DT, H13)
		var result := system.hourly_step(rng)
		for incident in result["incidents"]:
			log.append("%d|%s|%s|%.6f" % [h, String(incident["kind"]),
					String(incident["target_id"]), float(incident["severity"])])
	return log


# --- test 17: determinism --------------------------------------------------

func test_failure_determinism_same_seed() -> void:
	var a := _rig({"pump_condition": 0.5})
	var b := _rig({"pump_condition": 0.5})
	var log_a := _run_hours(a, RngStreams.new(4242), 500, false)
	var log_b := _run_hours(b, RngStreams.new(4242), 500, false)
	assert_true(log_a.size() > 0, "500 game-hours at condition 0.5 must produce failures")
	assert_eq(log_b, log_a, "same seed ⇒ identical ids, tiles and severities")
	assert_eq(a.serialize()["stats"], b.serialize()["stats"])


func test_failure_determinism_live_vs_offline() -> void:
	var live := _rig({"pump_condition": 0.5})
	var offline := _rig({"pump_condition": 0.5})
	var log_live := _run_hours(live, RngStreams.new(99), 500, false)
	var log_offline := _run_hours(offline, RngStreams.new(99), 500, true)
	assert_eq(log_offline, log_live,
			"the hourly roll is one code path — offline catch-up cannot diverge")


func test_advance_twice_gives_identical_capture() -> void:
	# The constitution's determinism gate, applied to this section alone.
	var a := _rig()
	var b := _rig()
	var rng_a := RngStreams.new(7)
	var rng_b := RngStreams.new(7)
	_run_hours(a, rng_a, 48, false)
	_run_hours(b, rng_b, 48, false)
	assert_eq(JSON.stringify(CitySim._encode_floats(b.serialize())),
			JSON.stringify(CitySim._encode_floats(a.serialize())),
			"two runs from the same seed capture bit-identically")


# --- test 18: the freeze multiplier (example E) ---------------------------

func test_freeze_multiplier() -> void:
	var model := WaterFailureModel.new(_data())
	var stress := 0.0
	for h in 3:
		stress = model.step_freeze_stress(stress, -12.0, 0, 1.0)
	assert_almost_eq(stress, 1.8, 0.01, "((−6) − (−12)) / 10 × 3 game-hours")
	assert_almost_eq(model.freeze_mult(stress), 5.50, 0.01, "1 + 2.5 × 1.8")
	assert_almost_eq(model.cond_mult(0.70), 1.54, 0.01, "1 + 6 × 0.30²")
	var insulated := 0.0
	for h in 3:
		insulated = model.step_freeze_stress(insulated, -12.0, 2, 1.0)
	assert_almost_eq(insulated, 0.18, 0.01, "insulation 2 cuts the stress by 90 %")
	assert_almost_eq(model.freeze_mult(insulated), 1.45, 0.01)
	# Thaw is unconditional above the threshold.
	assert_almost_eq(model.step_freeze_stress(1.8, 5.0, 0, 1.0), 1.3, 0.001)
	assert_almost_eq(model.freeze_mult(10.0), 6.0, 0.001, "capped at freeze_mult_cap")


func test_freeze_hazard_gain_calibration() -> void:
	# §2.9's calibration, verified against DOC 06's rate expression: a 0.10 km
	# segment at condition 0.70 under a stress-1.8 freeze must reproduce this
	# doc's old standalone hazard of 0.00186/h to three significant figures.
	var model := WaterFailureModel.new(_data())
	var doc06_rate := DOC06_R_WM_BASE * 0.10 * model.cond_mult(0.70) * 1.0 \
			* model.freeze_mult(1.8)
	assert_almost_eq(doc06_rate, 0.001863, 0.00001)
	var standalone := 0.000040 * model.cond_mult(0.70) + 0.0020 * 1.8 * (1.2 - 0.70)
	assert_almost_eq(standalone, 0.001862, 0.00001)
	assert_true(absf(doc06_rate - standalone) / standalone < 0.005,
			"the two agree to better than 0.5 %% — that is what 2.5 was solved for")


func test_multipliers_published_to_doc06() -> void:
	var system := _rig()
	system.advance(DT, H13)
	system.edge("M1").condition = 0.70
	system.edge("M1").freeze_stress = 1.8
	var rows := system.mains()
	assert_eq(rows.size(), 1)
	var row: Dictionary = rows[0]
	assert_eq(String(row["segment_id"]), "M1")
	assert_almost_eq(float(row["cond_mult"]), 1.54, 0.01)
	assert_almost_eq(float(row["freeze_mult"]), 5.50, 0.01)
	assert_almost_eq(float(row["load_mult"]), 1.0, 0.001, "well under the 0.85 knee")
	assert_almost_eq(float(row["length_km"]), 4.0 * 0.008, 0.0001, "4 segments × 8 m")
	assert_almost_eq(float(row["break_rate_mult"]), 0.6, 0.001, "a trunk breaks less often")
	# The load knee: utilization 1.00 → 1 + 1.5 × 0.15/0.15 = 2.5.
	assert_almost_eq(system.failure_model.main_load_mult(1.00), 2.5, 0.001)
	assert_almost_eq(system.failure_model.main_load_mult(0.85), 1.0, 0.001)
	assert_almost_eq(system.failure_model.pump_load_mult(1.00), 2.5, 0.001)


func test_age_and_weather_multipliers() -> void:
	var model := WaterFailureModel.new(_data())
	assert_almost_eq(model.age_mult(0.0), 1.0, 0.001)
	assert_almost_eq(model.age_mult(60.0 * 1440.0), 1.15, 0.001, "one 60-day step")
	assert_almost_eq(model.age_mult(600.0 * 1440.0), 2.0, 0.001, "capped at 2.0")
	assert_almost_eq(model.weather_mult("flood"), 1.80, 0.001)
	assert_almost_eq(model.weather_mult("thunderstorm"), 1.20, 0.001)
	assert_almost_eq(model.weather_mult("clear"), 1.00, 0.001, "no row ⇒ no modifier")


func test_condition_decay_curve() -> void:
	var model := WaterFailureModel.new(_data())
	# §2.12: at full funding a pump ages 1.0 → 0.0 in ≈10,000 game-hours.
	var condition := 1.0
	for h in 10000:
		condition = model.decayed_condition(condition, "pump", 1.0, 1.0)
	assert_almost_eq(condition, 0.0, 0.001, "full funding: 0.0001 × 1.0 × 10,000")
	# At zero funding the same pump is dead in 4,000 game-hours (2.5× faster).
	var starved := 1.0
	for h in 4000:
		starved = model.decayed_condition(starved, "pump", 0.0, 1.0)
	assert_almost_eq(starved, 0.0, 0.001)


# --- test 19: repair work content and damage_fraction (C-16) --------------

func test_repair_work_and_damage_fraction() -> void:
	var jobs := WaterRepairJobs.new(_data())
	assert_almost_eq(jobs.work_minutes("main_break", 0.7, "water_heavy_truck"),
			38.667, 0.01, "50 × (0.6 + 0.8×0.7) / 1.5")
	assert_almost_eq(jobs.work_minutes("main_break", 0.7, "water_repair_truck"),
			58.0, 0.01, "the same work content at crew_mult 1.0")
	assert_almost_eq(jobs.work_minutes("main_break", 0.7, "water_repair_truck",
			{"frozen": true}), 92.8, 0.01, "a freeze break takes 1.6×")
	assert_almost_eq(jobs.work_minutes("pump_failure", 0.5, "water_repair_truck"),
			90.0, 0.01)
	var model := WaterFailureModel.new(_data())
	assert_almost_eq(model.damage_fraction(0.4, false), 0.90, 0.001)
	assert_almost_eq(model.damage_fraction(0.7, false), 1.00, 0.001)
	assert_almost_eq(model.damage_fraction(1.0, false), 1.00, 0.001)
	assert_almost_eq(model.damage_fraction(0.30, true), 0.92, 0.001,
			"frozen: 0.80 × 1.15 — the ×1.15 only bites below severity 0.37")
	assert_almost_eq(model.damage_fraction(0.4, true), 1.00, 0.001, "0.90 × 1.15 clamps")


func test_the_system_exposes_no_cost_method() -> void:
	# C-16 / C-07: doc 03 is the sole currency authority. Water publishes
	# `damage_fraction` and dimensionless ratios, never a price.
	var system := _rig()
	for method in system.get_method_list():
		var name := String(method["name"]).to_lower()
		assert_false(name.contains("cost") or name.contains("price"),
				"WaterSystem.%s must not exist — doc 03 prices water" % name)
	for method in WaterRepairJobs.new(_data()).get_method_list():
		var name := String(method["name"]).to_lower()
		assert_false(name.contains("cost") or name.contains("price"),
				"WaterRepairJobs.%s must not exist" % name)


func test_repair_lifecycle_restores_the_node() -> void:
	var system := _rig({"pump_condition": 0.4})
	system.advance(DT, H13)
	(system.node("PMP") as WaterNode).state = &"failed"
	var job := system.repairs.create({"kind": "pump_failure", "target_kind": "node",
			"target_id": "PMP", "tile": Vector2i(10, 10), "severity": 0.5,
			"damage_fraction": 1.0}, system.now_minutes)
	system.repairs.assign(int(job["job_id"]), "TRUCK-1", "water_repair_truck")
	assert_almost_eq(float(job["work_remaining_min"]), 90.0, 0.01)
	var done := system.repairs.advance(89.0)
	assert_true(done.is_empty(), "89 crew-minutes is not enough")
	done = system.repairs.advance(2.0)
	assert_eq(done.size(), 1)
	system._complete_repair(done[0])
	assert_eq((system.node("PMP") as WaterNode).state, &"ok")
	assert_almost_eq((system.node("PMP") as WaterNode).condition, 0.90, 0.001,
			"post_repair_condition for a pump failure")
	var events: Array = []
	for event in system.drain_events():
		events.append(String(event["type"]))
	assert_true(events.has("water_repair_completed"))


func test_heavy_truck_burns_work_faster() -> void:
	var jobs := WaterRepairJobs.new(_data())
	var job := jobs.create({"kind": "main_break", "target_kind": "edge",
			"target_id": "M1", "tile": Vector2i.ZERO, "severity": 0.7}, 0.0)
	jobs.assign(int(job["job_id"]), "HEAVY-1", "water_heavy_truck")
	# 58 crew-minutes at 1.5 crew-minutes per game-minute = 38.67 game-minutes.
	assert_true(jobs.advance(38.0).is_empty())
	assert_eq(jobs.advance(1.0).size(), 1)


# --- test 21: abandonment thresholds --------------------------------------

func test_abandonment_threshold() -> void:
	var system := _rig({"no_tank": true})
	system.powered_provider = func(_ref: String) -> bool: return false
	for i in 240:
		system.advance(DT, H13)
	assert_almost_eq(system.pressure_at(Vector2i(11, 12)), 0.0, 0.01, "dry")
	for h in 35:
		system._step_no_water_counters(1.0)
	assert_almost_eq(system.no_water_hours("H0"), 35.0, 0.001)
	assert_almost_eq(system.abandonment_rate_per_hour("H0"), 0.0, 1e-9,
			"35 h of no water and nobody has left yet")
	system._step_no_water_counters(1.0)
	assert_almost_eq(system.abandonment_rate_per_hour("H0"), 0.005, 1e-9,
			"at 36 h residents leave at 0.5 %/game-hour")
	# Restoring pressure to 0.4 decays the counter at 4 h per game-hour.
	system.powered_provider = Callable()
	for i in 240:
		system.advance(DT, H13)
	assert_true(system.pressure_at(Vector2i(11, 12)) >= 0.35)
	system._step_no_water_counters(1.0)
	assert_almost_eq(system.no_water_hours("H0"), 32.0, 0.001)
	assert_almost_eq(system.abandonment_rate_per_hour("H0"), 0.0, 1e-9)


# --- test 22: the contamination stub --------------------------------------

func test_contamination_stub() -> void:
	var system := _rig()
	for i in 240:
		system.advance(DT, H13)
	var hydrant_before := system.hydrant_pressure_ratio(Vector2i(11, 12))
	var pressure_before: float = (system.topology.zones[0] as PressureZone).pressure
	system.data.contamination["on_treatment_fail_chance"] = 1.0  # forced roll
	system._step_contamination(RngStreams.new(3), [{"kind": "treatment_failure",
			"target_kind": "node", "target_id": "TRT", "severity": 0.5}], 1.0)
	var z: PressureZone = system.topology.zones[0]
	assert_true(z.contaminated, "a boil-water advisory is raised")
	assert_almost_eq(z.contaminated_until_minutes - system.now_minutes, 720.0, 0.001,
			"12 game-hours")
	assert_true(system.get_water_service("H0")["contaminated"])
	system.advance(DT, H13)
	assert_almost_eq(system.topology.zones[0].pressure, pressure_before, 0.001,
			"contamination has NO pressure effect (§2.10)")
	assert_almost_eq(system.hydrant_pressure_ratio(Vector2i(11, 12)), hydrant_before, 0.001,
			"…and no hydrant effect — fire suppression is unaffected")
	assert_almost_eq(float(system.data.contamination["happiness_penalty"]), 12.0, 0.001)
	var kinds: Array = []
	for event in system.drain_events():
		kinds.append(String(event["type"]))
	assert_true(kinds.has("water_contamination_started"))


func test_contamination_clears_only_after_repair_and_flush() -> void:
	var system := _rig()
	system.advance(DT, H13)
	system.data.contamination["on_treatment_fail_chance"] = 1.0
	(system.node("TRT") as WaterNode).state = &"failed"
	system._step_contamination(RngStreams.new(3), [{"kind": "treatment_failure",
			"target_kind": "node", "target_id": "TRT", "severity": 0.5}], 1.0)
	var z: PressureZone = system.topology.zones[0]
	assert_true(z.contaminated)
	system.now_minutes += 800.0  # past contamination_base_minutes
	for h in 6:
		system._step_contamination(RngStreams.new(3), [], 1.0)
	assert_true(z.contaminated, "the plant is still down — the advisory holds")
	(system.node("TRT") as WaterNode).state = &"ok"
	for h in 6:
		system._step_contamination(RngStreams.new(3), [], 1.0)
	assert_false(z.contaminated, "plant repaired + 360 flush minutes ⇒ cleared")


# --- test 27: save round-trip ---------------------------------------------

func test_save_roundtrip() -> void:
	var system := _rig({"pump_condition": 0.8})
	var rng := RngStreams.new(2026)
	_run_hours(system, rng, 12, false)
	system.set_segment_broken("M1", 0.62, "INC-77", -0.35)
	system.register_fire_engines("FIRE-1", Vector2i(12, 12), 2)
	system.zone_pressure_delta(system.topology.zones[0].zone_key, "INC-88", -0.15)
	for i in 120:
		system.advance(DT, H13)
	var saved := system.serialize()
	var text := JSON.stringify(CitySim._encode_floats(saved))
	var restored := WaterSystem.new(_data(), 64)
	restored.deserialize(CitySim._decode_floats(JSON.parse_string(text)))
	assert_eq(restored.topology.zones.size(), system.topology.zones.size())
	for i in system.topology.zones.size():
		var a: PressureZone = system.topology.zones[i]
		var b: PressureZone = restored.topology.zones[i]
		assert_eq(b.zone_key, a.zone_key)
		assert_almost_eq(b.pressure, a.pressure, 1e-4, "zone pressure survives")
		assert_almost_eq(b.tank_volume_m3, a.tank_volume_m3, 1e-4)
	for node_id in ["PMP", "TNK", "SRC", "TRT"]:
		assert_almost_eq((restored.node(node_id) as WaterNode).condition,
				(system.node(node_id) as WaterNode).condition, 1e-9, node_id)
	assert_eq(String(restored.edge("M1").state), String(system.edge("M1").state))
	assert_almost_eq(restored.edge("M1").severity, system.edge("M1").severity, 1e-9)
	assert_eq(restored.edge("M1").owning_incident, "INC-77")
	assert_almost_eq(restored.edge("M1").incident_pressure_penalty, 0.35, 1e-9,
			"the penalty persists as a magnitude — no negative float in the section")
	assert_almost_eq(restored.water_service_factor_hour("H0"),
			system.water_service_factor_hour("H0"), 1e-4)
	assert_eq(restored.repairs.jobs.size(), system.repairs.jobs.size())
	# …and the two continue in lockstep.
	for i in 240:
		system.advance(DT, H13)
		restored.advance(DT, H13)
	assert_almost_eq(restored.topology.zones[0].pressure,
			system.topology.zones[0].pressure, 1e-9, "no divergence after load")
	assert_eq(JSON.stringify(CitySim._encode_floats(restored.serialize())),
			JSON.stringify(CitySim._encode_floats(system.serialize())))


func test_migrate_v1_to_v2() -> void:
	var v1 := {
		"section_version": 1,
		"nodes": [{"id": "41", "kind": "pump", "level": 2, "tile": [96, 48],
				"condition": 0.93, "state": "ok", "built_at_minutes": 128340,
				"backup": {"installed": true, "kw": 87, "fuel_l": 320.0},
				"fuel_l": 320.0, "start_timer_min": 0.0}],
		"edges": [{"id": "210", "a": "41", "b": "58", "tier": "trunk",
				"path": [[96, 48]], "condition": 0.88, "state": "broken", "severity": 0.7}],
		"jobs": {"jobs": [{"job_id": 88, "kind": "main_break", "target_kind": "edge",
				"target_id": "210", "tile": [97, 48], "severity": 0.7,
				"work_remaining_min": 34.5, "assigned_vehicle": "12",
				"vehicle_type": "water_repair_truck", "created_at_minutes": 131020}],
				"next_job_id": 89},
		"policy": {"water_restrictions": false, "auto_dispatch_water": true,
				"auto_refuel_backup": true},
	}
	var v2 := WaterSystem.migrate_water_v1_to_v2(v1)
	assert_eq(int(v2["section_version"]), 2)
	var node_record: Dictionary = v2["nodes"][0]
	assert_eq(String(node_record["variant"]), "pump", "kind → variant")
	assert_false(node_record.has("kind"))
	assert_true(bool(node_record["backup_installed"]), "backup object → boolean")
	assert_false(node_record.has("fuel_l"), "C-36: fuel moves to doc 04's section")
	assert_false(node_record.has("start_timer_min"))
	assert_eq(String((v2["edges"][0] as Dictionary)["owning_incident"]), "", "C-46 field added")
	assert_true((v2["jobs"]["jobs"][0] as Dictionary).has("damage_fraction"), "C-16 field added")
	assert_false((v2["policy"] as Dictionary).has("auto_refuel_backup"))
	assert_true(v2.has("service"), "C-37: service_accum section added")
	# A v2 body passes through untouched.
	assert_eq(WaterSystem.migrate_water_v1_to_v2(v2), v2)
	# …and the migrated body actually loads.
	var system := WaterSystem.new(_data(), 128)
	system.deserialize(v2)
	assert_eq((system.node("41") as WaterNode).variant, &"pump")
	assert_true((system.node("41") as WaterNode).backup_installed)


# --- events ---------------------------------------------------------------

func test_zone_notifications() -> void:
	var system := _rig({"no_tank": true, "house_demand": 8.0})
	system.advance(DT, H13)
	system.drain_events()
	system.powered_provider = func(_ref: String) -> bool: return false
	for i in 240:
		system.advance(DT, H13)
	var kinds: Dictionary = {}
	for event in system.drain_events():
		kinds[String(event["type"])] = true
	assert_true(kinds.has("water_pump_tripped"))
	assert_true(kinds.has("water_capacity_shortage"), "20 sustained minutes below ratio 0.98")
	assert_true(kinds.has("water_pressure_low"))
	assert_true(kinds.has("water_zone_offline"), "P1: the zone went dry")
	system.powered_provider = Callable()
	for i in 240:
		system.advance(DT, H13)
	var restored: Dictionary = {}
	for event in system.drain_events():
		restored[String(event["type"])] = true
	assert_true(restored.has("water_pressure_restored"))


func test_tank_events() -> void:
	var system := _rig({"house_demand": 40.0})
	system.advance(DT, H13)
	system.drain_events()
	system.powered_provider = func(_ref: String) -> bool: return false
	var kinds: Dictionary = {}
	for i in 240 * 4:
		system.advance(DT, H13)
		for event in system.drain_events():
			kinds[String(event["type"])] = int(kinds.get(String(event["type"]), 0)) + 1
	assert_eq(int(kinds.get("water_tank_low", 0)), 1, "one low warning, not one per tick")
	assert_eq(int(kinds.get("water_tank_empty", 0)), 1)
	assert_true(kinds.has("water_pump_tripped"))


func test_every_documented_event_name_is_reachable() -> void:
	# Doc 05 §4's emitted list, minus the two doc-04 events C-36 deleted.
	var documented := ["water_main_break", "water_main_isolated", "water_pump_failed",
			"water_pump_tripped", "water_treatment_failed", "water_source_failed",
			"water_freeze_break", "water_tank_low", "water_tank_empty",
			"water_capacity_shortage", "water_zone_offline", "water_pressure_low",
			"water_pressure_restored", "water_contamination_started",
			"water_contamination_cleared", "water_incident_raised", "water_repair_completed"]
	var text := FileAccess.get_file_as_string("res://sim/water/water_system.gd")
	for name: String in documented:
		assert_true(text.contains("&\"%s\"" % name), "no emit site for %s" % name)
	for deleted: String in ["water_backup_started", "water_backup_fuel_out"]:
		assert_false(text.contains(deleted),
				"C-36: doc 04 emits the generator lifecycle, not water")


func test_overlay_snapshot_shape() -> void:
	var system := _rig()
	system.set_segment_broken("M1", 0.5, "INC-1", -0.35)
	for i in 60:
		system.advance(DT, H13)
	var snapshot := system.get_overlay_snapshot()
	assert_eq((snapshot["zones"] as Array).size(), 1)
	var zone: Dictionary = snapshot["zones"][0]
	for key: String in ["zone_key", "pressure", "demand_m3h", "supply_m3h", "delivered_m3h",
			"tank_volume_m3", "tank_capacity_m3", "buffer_hours", "contaminated",
			"dead", "color_band"]:
		assert_true(zone.has(key), "overlay zone row is missing %s" % key)
	assert_true(["normal", "warn", "critical", "none"].has(String(zone["color_band"])),
			"the band is a NAME, so the overlay can pair colour with an icon")
	assert_eq((snapshot["nodes"] as Array).size(), 4, "junctions are not build cards")
	for node_row: Dictionary in snapshot["nodes"]:
		assert_false(node_row.has("fuel_hours_left"),
				"C-36: doc 04's generator panel owns fuel, not the water overlay")
	assert_eq(int(snapshot["city"]["active_breaks"]), 1)
	assert_true(float(snapshot["city"]["water_health_pct"]) >= 0.0)
	assert_eq((snapshot["tiles"] as PackedByteArray).size(), 64 * 64)
