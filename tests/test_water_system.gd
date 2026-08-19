extends SimTest
## Doc 05 §7 tests 2–16, 20, 23, 25 — the mass balance, the zone graph, the
## power cascade and the worked examples A–F, all in rescaled units (R-09/R-10).
##
## §2.14's channel values are STATED INPUTS so every example is reproducible:
## `water_demand_residential` 1.075 @ h13 / 1.333 @ h19 / 1.025 @ h22 and
## `water_demand_commercial` 1.65 @ h13 / 1.00 @ h19 / 0.45 @ h22. They are
## injected here rather than sampled from `data/time.json` for exactly the
## reason the doc names them: the example must not move when a curve is retuned.

const DT := 1.0 / 240.0  # EVERY_TICK = 15 game-seconds
const H13 := {"water_demand_residential": 1.075, "water_demand_commercial": 1.65}
const H19 := {"water_demand_residential": 1.333, "water_demand_commercial": 1.00}
const H22 := {"water_demand_residential": 1.025, "water_demand_commercial": 0.45}


func _data() -> WaterData:
	return WaterData.from_dict(StarterCityLoader.read_json("res://data/water.json"))


## Doc 09's `WTR-1` shape: intake + treatment skid + pump house co-located on
## one terminal, an elevated tank up the riser, one main joining them.
func _rig(opts: Dictionary = {}) -> WaterSystem:
	var system := WaterSystem.new(_data(), 64)
	var upstream := int(opts.get("upstream_level", 1))
	system.add_node("SRC", &"source", Vector2i(10, 10),
			{"level": upstream, "subtype": "river", "power_ref": "WTR"})
	system.add_node("TRT", &"treatment", Vector2i(10, 10),
			{"level": upstream, "power_ref": "WTR"})
	system.add_node("PMP", &"pump", Vector2i(10, 10),
			{"level": int(opts.get("pump_level", 1)),
			"condition": float(opts.get("pump_condition", 1.0)), "power_ref": "WTR"})
	if not bool(opts.get("no_tank", false)):
		system.add_node("TNK", &"tank", Vector2i(10, 14),
				{"level": int(opts.get("tank_level", 1)), "power_ref": "WTR-TANK"})
	system.add_main("M1", [Vector2i(10, 10), Vector2i(10, 14)],
			{"tier": String(opts.get("tier", "trunk"))})
	return system


## §2.4 owns only the SPLIT, so a target (res, com, proc) triple is seeded with
## real archetypes: house is pure res, office is 0.73/0.27, substation pure proc.
func _seed_zone(system: WaterSystem, res: float, com: float, proc: float) -> void:
	var office_w := com / 0.73
	var substation_w := proc - office_w * 0.27
	assert_true(substation_w >= -1e-9, "seed triple is reachable from the split table")
	system.attach_building("B-RES", Vector2i(11, 12), "house")
	system.attach_building("B-COM", Vector2i(11, 13), "office")
	system.attach_building("B-PROC", Vector2i(9, 12), "substation")
	system.set_demands({"B-RES": res, "B-COM": office_w, "B-PROC": maxf(substation_w, 0.0)})


func _set_tank(system: WaterSystem, volume: float) -> void:
	(system.node("TNK") as WaterNode).volume_m3 = volume


func _zone(system: WaterSystem) -> PressureZone:
	return system.topology.zones[0]


func _advance(system: WaterSystem, channels: Dictionary, ticks: int) -> void:
	for i in ticks:
		system.advance(DT, channels)


# --- test 2: demand aggregation -------------------------------------------

func test_demand_aggregation() -> void:
	var system := _rig()
	for i in 10:
		system.attach_building("H%d" % i, Vector2i(11, 12), "house")
	system.attach_building("S0", Vector2i(11, 13), "store")
	system.attach_building("S1", Vector2i(9, 12), "store")
	var demands: Dictionary = {"S0": 0.30, "S1": 0.30}
	for i in 10:
		demands["H%d" % i] = 0.08
	system.set_demands(demands)
	system.advance(DT, H13)
	var z := _zone(system)
	assert_almost_eq(z.res_base, 0.80, 0.0005, "10 × house L1 at share res 1.00")
	assert_almost_eq(z.com_base, 0.33, 0.0005, "2 × store L2 at share com 0.55")
	assert_almost_eq(z.proc_base, 0.27, 0.0005, "…and proc 0.45")
	assert_almost_eq(z.demand_m3h, 1.6745, 0.0005,
			"0.80×1.075 + 0.33×1.65 + 0.27 (doc 05 §7 test 2)")


func test_demand_cache_is_event_driven() -> void:
	var system := _rig()
	system.attach_building("H0", Vector2i(11, 12), "house")
	system.set_demands({"H0": 0.08})
	system.advance(DT, H13)
	assert_almost_eq(_zone(system).res_base, 0.08, 1e-9)
	# Doc 02 upgrades the house L1 → L2: the sum moves without a rescan.
	system.set_demands({"H0": 0.19})
	system.advance(DT, H13)
	assert_almost_eq(_zone(system).res_base, 0.19, 1e-9)
	system.detach_building("H0")
	system.advance(DT, H13)
	assert_almost_eq(_zone(system).res_base, 0.0, 1e-9, "demolition backs the row out")


# --- test 3: zone partition ------------------------------------------------

func test_zone_partition() -> void:
	var system := WaterSystem.new(_data(), 64)
	system.add_node("SRC-A", &"source", Vector2i(5, 5), {"subtype": "river"})
	system.add_node("TRT-A", &"treatment", Vector2i(5, 5))
	system.add_node("PMP-A", &"pump", Vector2i(5, 5))
	system.add_main("MA", [Vector2i(5, 5), Vector2i(5, 9)])
	system.add_node("SRC-B", &"source", Vector2i(40, 40), {"subtype": "river"})
	system.add_node("TRT-B", &"treatment", Vector2i(40, 40))
	system.add_node("PMP-B", &"pump", Vector2i(40, 40))
	system.add_main("MB", [Vector2i(40, 40), Vector2i(40, 44)])
	system.rebuild_zones()
	assert_eq(system.topology.zones.size(), 2, "two unconnected clusters = two zones")
	# One main closes the loop and the two become one zone.
	system.add_main("MJOIN", [Vector2i(5, 9), Vector2i(40, 9), Vector2i(40, 40)])
	system.rebuild_zones()
	assert_eq(system.topology.zones.size(), 1, "joining them merges the components")
	assert_eq(_zone(system).zone_key, "PMP-A", "zone_key = smallest facility node id")


func test_dead_zone_has_no_pressure() -> void:
	var system := WaterSystem.new(_data(), 64)
	system.add_node("SRC", &"source", Vector2i(5, 5), {"subtype": "river"})
	system.add_main("M", [Vector2i(5, 5), Vector2i(5, 9)])
	system.attach_building("B", Vector2i(6, 7), "house")
	system.set_demands({"B": 0.08})
	_advance(system, H13, 40)
	assert_true(_zone(system).dead, "a component with no pump or tank is a dead zone")
	assert_almost_eq(system.pressure_at(Vector2i(6, 7)), 0.0, 0.001)


# --- test 4: per-tile static factor ---------------------------------------

func test_tile_factor() -> void:
	var system := _rig()
	system.rebuild_zones()
	# Chebyshev distance from the M1 tile column x = 10, z ∈ [10, 14].
	assert_almost_eq(system.topology.factor_at_tile(Vector2i(10, 12)), 1.00, 0.0001, "d = 0")
	assert_almost_eq(system.topology.factor_at_tile(Vector2i(12, 12)), 1.00, 0.0001, "d = 2")
	assert_almost_eq(system.topology.factor_at_tile(Vector2i(15, 12)), 0.70, 0.0001, "d = 5")
	assert_almost_eq(system.topology.factor_at_tile(Vector2i(22, 12)), 0.00, 0.0001, "d = 12")
	assert_eq(system.topology.zone_at_tile(Vector2i(22, 12)), 0, "d = 12 is still in the zone")
	assert_eq(system.topology.zone_at_tile(Vector2i(23, 12)), -1, "d = 13 is unserved")
	assert_almost_eq(system.pressure_at(Vector2i(23, 12)), 0.0, 0.0001)


func test_elevation_head_penalty() -> void:
	# §2.3: a tank at 30 m of head serving tiles at 60 m → 1 − 0.015×30 = 0.55.
	var grid := TileGrid.new()
	for bz in TileGrid.BLOCKS:
		for bx in TileGrid.BLOCKS:
			grid.set_block_elevation(bx, bz, 64)
	var system := WaterSystem.new(_data(), TileGrid.SIZE)
	system.terrain = grid
	system.add_node("TNK", &"tank", Vector2i(10, 10))
	system.add_main("M", [Vector2i(10, 10), Vector2i(10, 14)])
	system.rebuild_zones()
	# head_z = the tank's 30 m; elevation 64 m → 1 − 0.015 × 34 = 0.49.
	assert_almost_eq(system.topology.factor_at_tile(Vector2i(10, 12)), 0.49, 0.0001)
	# A booster adds 25 m of head and the penalty shrinks accordingly.
	system.add_node("BST", &"booster", Vector2i(10, 12))
	system.rebuild_zones()
	assert_almost_eq(system.topology.factor_at_tile(Vector2i(10, 12)),
			1.0 - 0.015 * (64.0 - 55.0), 0.0001, "+25 m of booster head")


# --- test 5: pressure converges -------------------------------------------

func test_pressure_full_supply() -> void:
	var system := _rig()
	_seed_zone(system, 4.0, 1.0, 0.4)
	system.advance(DT, H19)
	_set_tank(system, 60.0)  # 50 % of the L1 tank
	_zone(system).pressure = 0.0
	_advance(system, H19, 20)
	# tau = 0.05 gh = 3 game-minutes = 12 ticks, so 20 ticks is ~1.7 τ.
	assert_true(_zone(system).pressure > 0.80, "P climbs past 0.80 within 20 ticks")
	_advance(system, H19, 100)
	assert_almost_eq(_zone(system).pressure, 1.0, 0.001, "…and settles at 1.0")


# --- tests 6-9: the tank, exactly (example A / B) --------------------------

func test_example_a_demand_and_supply() -> void:
	var system := _rig({"pump_condition": 0.95})
	_seed_zone(system, 16.0, 4.0, 1.6)
	system.advance(DT, H19)
	var z := _zone(system)
	assert_almost_eq(z.res_base, 16.0, 0.0005)
	assert_almost_eq(z.com_base, 4.0, 0.0005)
	assert_almost_eq(z.proc_base, 1.6, 0.0005)
	assert_almost_eq(z.demand_m3h, 26.928, 0.002, "example A: 21.33 + 4.00 + 1.60")
	assert_almost_eq(z.supply_m3h, 39.0, 0.002, "40.0 × 1.0 × (0.5 + 0.5×0.95)")
	assert_almost_eq(z.pressure, 1.0, 0.0001)


func test_tank_drain_exact() -> void:
	var system := _rig({"pump_condition": 0.95})
	_seed_zone(system, 16.0, 4.0, 1.6)
	_set_tank(system, 108.0)
	system.advance(DT, H19)
	_set_tank(system, 108.0)
	# The substation trips: no power, no backup → below the 0.35 trip fraction.
	system.powered_provider = func(_ref: String) -> bool: return false
	var crossed_low := -1.0
	var emptied := -1.0
	for i in 240 * 5:
		system.advance(DT, H19)
		var z := _zone(system)
		if crossed_low < 0.0 and z.level_frac() <= 0.15:
			crossed_low = float(i + 1) * DT
		if emptied < 0.0 and z.tank_volume_m3 <= 0.0:
			emptied = float(i + 1) * DT
		if absf(float(i + 1) * DT - 3.0) < 1e-9:
			assert_almost_eq(z.tank_volume_m3, 27.216, 0.10,
					"example A: 108 − 26.93 × 3 after exactly 3.00 game-hours")
			assert_almost_eq(z.pressure, 1.0, 0.001,
					"ratio is still 1.0 — the tank is paying, nothing looks wrong yet")
	assert_almost_eq(crossed_low, 3.343, 0.02, "level_frac crosses 0.15 at 3.34 gh")
	assert_almost_eq(emptied, 4.011, 0.02, "empty at 4.01 gh")
	assert_almost_eq(_zone(system).pressure, 0.0, 0.02, "…and then P = 0")
	assert_true(_zone(system).tank_volume_m3 >= 0.0, "no negative volume")


func test_tank_drain_offline_equivalence() -> void:
	# The SAME code path at dt = 1 gh (doc 08 catch-up) and dt = 1/240 gh.
	var fine := _rig({"pump_condition": 0.95})
	_seed_zone(fine, 16.0, 4.0, 1.6)
	fine.advance(DT, H19)
	_set_tank(fine, 108.0)
	fine.powered_provider = func(_ref: String) -> bool: return false
	for i in 240 * 3:
		fine.advance(DT, H19)
	var coarse := _rig({"pump_condition": 0.95})
	_seed_zone(coarse, 16.0, 4.0, 1.6)
	coarse.advance(DT, H19)
	_set_tank(coarse, 108.0)
	coarse.powered_provider = func(_ref: String) -> bool: return false
	for i in 3:
		coarse.advance(1.0, H19)
	var fine_volume := _zone(fine).tank_volume_m3
	var coarse_volume := _zone(coarse).tank_volume_m3
	assert_almost_eq(coarse_volume, fine_volume, maxf(fine_volume * 0.01, 0.05),
			"offline and live agree within 1 %%")
	assert_true(coarse_volume >= 0.0, "no negative volume at dt = 1 gh")


func test_tank_low_head_factor() -> void:
	var system := _rig({"pump_condition": 0.95})
	_seed_zone(system, 16.0, 4.0, 1.6)
	system.advance(DT, H19)
	system.powered_provider = func(_ref: String) -> bool: return false
	_set_tank(system, 9.0)  # 7.5 % of 120 m³
	_advance(system, H19, 1)
	_set_tank(system, 9.0)
	_zone(system).pressure = 0.70
	_advance(system, H19, 1)
	# head_factor = 0.40 + 0.60 × (0.075 / 0.15) = 0.70, ratio still 1.0.
	assert_almost_eq(_zone(system).pressure, 0.70, 0.005)


func test_refill_caps() -> void:
	# Example B: 27.21 m³ at 22:00 with D = 19.80 and S = 39.0 refills in 4.83 gh,
	# against 4.01 gh to drain. Recovery costs more than the failure.
	var system := _rig({"pump_condition": 0.95})
	_seed_zone(system, 16.0, 4.0, 1.6)
	system.advance(DT, H22)
	_set_tank(system, 27.216)
	var z := _zone(system)
	var filled := -1.0
	for i in 240 * 6:
		system.advance(DT, H22)
		assert_true((system.node("TNK") as WaterNode).volume_m3 <= 120.0 + 1e-9,
				"never above capacity")
		if filled < 0.0 and z.tank_volume_m3 >= 119.999:
			filled = float(i + 1) * DT
	assert_almost_eq(z.demand_m3h, 19.80, 0.002, "16.40 + 1.80 + 1.60")
	assert_almost_eq(filled, 4.833, 0.05, "92.79 / 19.20 = 4.83 gh")


func test_refill_respects_max_inflow() -> void:
	# A huge surplus is still capped by the tank's max_inflow (26.5 at L1).
	var system := _rig({"pump_level": 3, "upstream_level": 3})
	_seed_zone(system, 1.0, 0.0, 0.0)
	system.advance(DT, H22)
	_set_tank(system, 0.0)
	var before := (system.node("TNK") as WaterNode).volume_m3
	system.advance(1.0, H22)
	assert_almost_eq((system.node("TNK") as WaterNode).volume_m3 - before, 26.5, 0.001,
			"one game-hour of refill = max_inflow_m3h exactly")


# --- tests 10-11: the power cascade (example D) ---------------------------

func test_power_dependency() -> void:
	var system := _rig({"pump_level": 2, "pump_condition": 0.90, "upstream_level": 2})
	_seed_zone(system, 30.0, 10.0, 5.0)
	system.advance(DT, H13)
	# Brownout at 0.60 (a backup module's coverage): 98.0 × 0.60 × 0.95.
	system.set_power_fraction_override("PMP", 0.60)
	system.advance(DT, H13)
	assert_almost_eq(_zone(system).supply_m3h, 55.86, 0.05, "example D derated flow")
	# 0.30 is below `pump_trip_fraction` 0.35 → the pump trips.
	system.set_power_fraction_override("PMP", 0.30)
	system.advance(DT, H13)
	assert_almost_eq(_zone(system).supply_m3h, 0.0, 1e-9, "tripped")
	assert_almost_eq((system.node("PMP") as WaterNode).restart_timer_min, 5.0, 1e-9)
	# Power returns: 5 game-minutes of lockout before it picks up again.
	system.set_power_fraction_override("PMP", 1.0)
	for i in 19:
		system.advance(DT, H13)
		assert_almost_eq(_zone(system).supply_m3h, 0.0, 1e-9,
				"still locked out at t = %.2f min" % (float(i + 1) * 0.25))
	system.advance(DT, H13)
	assert_almost_eq(_zone(system).supply_m3h, 98.0 * 0.95, 0.01,
			"resumes exactly 5 game-minutes after power returns")


func test_pump_trip_emits_once() -> void:
	var system := _rig()
	_seed_zone(system, 4.0, 1.0, 0.4)
	system.advance(DT, H19)
	system.drain_events()
	system.powered_provider = func(_ref: String) -> bool: return false
	_advance(system, H19, 10)
	var trips := 0
	for event in system.drain_events():
		if event["type"] == &"water_pump_tripped":
			trips += 1
	assert_eq(trips, 1, "one trip event, not one per tick")


func test_backup_coverage_published() -> void:
	var system := _rig({"pump_level": 2, "pump_condition": 0.90, "upstream_level": 2})
	_seed_zone(system, 30.0, 10.0, 5.0)
	var result := system.cmd_install_backup_generator("PMP")
	assert_true(bool(result["ok"]))
	var spec: Dictionary = result["payload"]
	assert_almost_eq(float(spec["kw_required"]), 145.0, 0.0001)
	assert_almost_eq(float(spec["coverage_frac"]), 0.60, 0.0001)
	assert_almost_eq(float(spec["backup_kw"]), 87.0, 0.0001)
	assert_eq(String(spec["priority_class"]), "CRITICAL")
	assert_true(bool(spec["backup_capable"]))
	# With doc 04 dark and the module fitted the pump runs at coverage_frac.
	system.powered_provider = func(_ref: String) -> bool: return false
	system.advance(DT, H13)
	system.advance(DT, H13)
	assert_almost_eq(_zone(system).supply_m3h, 55.86, 0.05)


func test_backup_needs_level_two() -> void:
	var system := _rig()
	assert_false(bool(system.cmd_install_backup_generator("PMP")["ok"]),
			"a module exists only at facility level ≥ 2 (§2.6)")
	# …and an L1 node with no module is simply dark.
	system.powered_provider = func(_ref: String) -> bool: return false
	assert_almost_eq(system.power_fraction_of(system.node("PMP")), 0.0, 1e-9)


# --- test 12: the simplified min-cut (example F) ---------------------------

func test_feed_capacity_bottleneck() -> void:
	var big := _rig({"pump_level": 5, "upstream_level": 5, "tier": "service"})
	_seed_zone(big, 400.0, 100.0, 50.0)
	big.advance(DT, H13)
	assert_almost_eq(_zone(big).supply_m3h, 53.5, 0.001,
			"an L5 pump behind one service main delivers 53.5")
	var trunk := _rig({"pump_level": 3, "pump_condition": 0.90, "upstream_level": 3,
			"tier": "trunk"})
	_seed_zone(trunk, 40.0, 20.0, 15.0)
	trunk.advance(DT, H13)
	assert_almost_eq(_zone(trunk).supply_m3h, 213.0, 0.001,
			"example F: 240 × 0.95 = 228 raw, throttled to the trunk's 213")


func test_upstream_capacity_splits_between_pumps() -> void:
	# §2.5: shared upstream is split in proportion to rated_flow_m3h.
	var system := WaterSystem.new(_data(), 64)
	system.add_node("SRC", &"source", Vector2i(10, 10), {"subtype": "river", "level": 1})
	system.add_node("TRT", &"treatment", Vector2i(10, 10), {"level": 1})  # 80 m³/h
	system.add_node("PMP-A", &"pump", Vector2i(10, 10), {"level": 1})  # 40
	system.add_node("PMP-B", &"pump", Vector2i(10, 11), {"level": 2})  # 98
	system.add_main("M", [Vector2i(10, 10), Vector2i(10, 14)], {"tier": "arterial"})
	system.rebuild_zones()
	assert_almost_eq(_zone(system).upstream_cap_m3h, 80.0, 0.001, "min(107, 80)")
	assert_almost_eq((system.node("PMP-A") as WaterNode).share_m3h,
			80.0 * 40.0 / 138.0, 0.001)
	assert_almost_eq((system.node("PMP-B") as WaterNode).share_m3h,
			80.0 * 98.0 / 138.0, 0.001)
	_seed_zone(system, 200.0, 0.0, 0.0)
	system.advance(DT, H13)
	assert_almost_eq(_zone(system).supply_m3h, 80.0, 0.01,
			"the two pumps together cannot exceed the treatment plant")


func test_treatment_failure_stops_the_zone() -> void:
	var system := _rig()
	_seed_zone(system, 4.0, 1.0, 0.4)
	system.advance(DT, H13)
	assert_true(_zone(system).supply_m3h > 0.0)
	(system.node("TRT") as WaterNode).state = &"failed"
	system.rebuild_zones()
	system.advance(DT, H13)
	assert_almost_eq(_zone(system).supply_m3h, 0.0, 1e-9,
			"no potable throughput upstream ⇒ no pump flow")


# --- tests 13-15: breaks, isolation and the fire cascade (example C) -------

func _example_c() -> WaterSystem:
	var system := _rig({"pump_level": 2, "pump_condition": 0.90, "upstream_level": 2,
			"tank_level": 2})
	_seed_zone(system, 30.0, 10.0, 5.0)
	system.advance(DT, H13)
	_set_tank(system, 205.8)  # 70 % of the L2 tank
	system.advance(DT, H13)
	return system


func test_example_c_baseline() -> void:
	var system := _example_c()
	var z := _zone(system)
	assert_almost_eq(z.demand_m3h, 53.75, 0.002, "32.25 + 16.50 + 5.00")
	assert_almost_eq(z.supply_m3h, 93.10, 0.01, "98.0 × 0.95")


func test_main_break_pressure() -> void:
	var system := _example_c()
	system.set_segment_broken("M1", 0.7, "INC-4412", -0.15)
	_advance(system, H13, 240)
	var z := _zone(system)
	assert_almost_eq(z.leak_m3h, 37.275, 0.02, "213 × 0.25 × 0.7")
	assert_almost_eq(z.demand_m3h, 91.025, 0.05, "53.75 + 37.28, still under S")
	assert_almost_eq(z.ratio, 1.0, 0.001)
	assert_almost_eq(z.pressure, 0.85, 0.002,
			"C-46: doc 06's tiered −0.15 wins over the flat fallback")


func test_main_break_fallback_penalty() -> void:
	var system := _example_c()
	# No owning incident: the standalone `break_pressure_penalty_fallback` path.
	system.set_segment_broken("M1", 0.7)
	_advance(system, H13, 240)
	assert_almost_eq(_zone(system).pressure, 0.916, 0.002, "1.0 − 0.12 × 0.7")


func test_break_penalty_is_capped() -> void:
	var system := _example_c()
	system.add_main("M2", [Vector2i(10, 12), Vector2i(16, 12)], {"tier": "service"})
	system.rebuild_zones()
	system.set_segment_broken("M1", 1.0, "INC-1", -0.80)
	system.set_segment_broken("M2", 1.0, "INC-2", -0.80)
	_advance(system, H13, 240)
	assert_almost_eq(_zone(system).pressure, 0.50, 0.002, "break_penalty_cap = 0.50")


func test_fire_draw_cascade() -> void:
	var system := _example_c()
	system.set_segment_broken("M1", 0.7, "INC-4412", -0.15)
	system.register_fire_engines("FIRE-1", Vector2i(13, 12), 2)
	_advance(system, H13, 240)
	var z := _zone(system)
	assert_almost_eq(z.fire_draw_m3h, 16.0, 0.001, "2 × fire_flow_per_engine_m3h 8.0")
	assert_almost_eq(z.demand_m3h, 107.025, 0.05)
	assert_almost_eq(z.ratio, 1.0, 0.001, "the tank is paying for the pressure")
	assert_almost_eq(z.pressure, 0.85, 0.002)
	# The fire tile is 3 tiles from the nearest main → prox 0.90.
	assert_almost_eq(system.topology.factor_at_tile(Vector2i(13, 12)), 0.90, 0.0001)
	var ratio := system.hydrant_pressure_ratio(Vector2i(13, 12))
	assert_almost_eq(ratio, 0.765, 0.005, "example C's hydrant_pressure_ratio")
	assert_almost_eq(clampf(0.25 + 0.75 * ratio, 0.25, 1.15), 0.824, 0.005,
			"…which is doc 06's hydrant_factor 0.824")
	system.clear_fire_draw("FIRE-1")
	system.advance(DT, H13)
	assert_almost_eq(_zone(system).fire_draw_m3h, 0.0, 1e-9)


func test_isolation() -> void:
	var system := _rig({"pump_level": 2, "upstream_level": 2})
	# A branch main reaching out to a neighbourhood 10 tiles away.
	system.add_main("M-BRANCH", [Vector2i(10, 14), Vector2i(30, 14)], {"tier": "service"})
	system.attach_building("FAR", Vector2i(30, 15), "house")
	system.set_demands({"FAR": 0.08})
	system.advance(DT, H13)
	assert_eq(system.topology.zones.size(), 1)
	assert_true(system.pressure_at(Vector2i(30, 15)) > 0.0)
	system.set_segment_broken("M-BRANCH", 0.7)
	system.advance(DT, H13)
	assert_true(_zone(system).leak_m3h > 0.0, "a broken main leaks…")
	assert_eq(system.topology.zones.size(), 1, "…but still conducts (example C)")
	assert_true(bool(system.cmd_isolate_main("M-BRANCH")["ok"]))
	system.advance(DT, H13)
	var total_leak := 0.0
	for z: PressureZone in system.topology.zones:
		total_leak += z.leak_m3h
	assert_almost_eq(total_leak, 0.0, 1e-9, "isolation takes the leak to zero")
	assert_true(system.topology.zones.size() > 1, "…and strands the branch")
	assert_almost_eq(system.pressure_at(Vector2i(30, 15)), 0.0, 0.001,
			"stranded tiles read No water — the intended trade")
	assert_true(bool(system.cmd_restore_main("M-BRANCH")["ok"]))
	system.advance(DT, H13)
	assert_eq(system.topology.zones.size(), 1)


# --- test 16: the hydrant contract ----------------------------------------

func test_hydrant_ratio_contract() -> void:
	var system := _example_c()
	_advance(system, H13, 60)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20260818
	for i in 4000:
		var tile := Vector2i(rng.randi_range(0, 63), rng.randi_range(0, 63))
		var ratio := system.hydrant_pressure_ratio(tile)
		assert_true(ratio >= 0.0 and ratio <= 1.2 and not is_nan(ratio),
				"hydrant ratio out of contract at %s: %f" % [str(tile), ratio])
	assert_almost_eq(system.hydrant_pressure_ratio(Vector2i(60, 60)), 0.0, 1e-9,
			"unserved tiles are dry, not defaulted")


func test_overpressure_needs_margin_and_storage() -> void:
	var system := _rig({"pump_level": 3, "upstream_level": 3})
	_seed_zone(system, 4.0, 1.0, 0.4)
	_advance(system, H13, 240 * 3)  # supply ≫ demand, tank fills to 100 %
	var z := _zone(system)
	assert_true(z.supply_m3h / z.demand_m3h >= 1.5, "S/D ≥ 1.5")
	assert_true(z.level_frac() >= 0.9, "tanks ≥ 90 %")
	assert_almost_eq(system.hydrant_pressure_ratio(Vector2i(10, 12)), 1.2, 0.001,
			"a strong system suppresses faster than nominal")
	# Drop the storage below 80 % and the bonus disappears.
	_set_tank(system, 60.0)
	system.advance(DT, H13)
	assert_almost_eq(system.hydrant_pressure_ratio(Vector2i(10, 12)), 1.0, 0.001)


# --- test 20: the effects table -------------------------------------------

func test_effects_table() -> void:
	var system := _rig()
	system.attach_building("B", Vector2i(11, 12), "house")
	system.set_demands({"B": 0.08})
	system.advance(DT, H13)
	var expected := [
		[0.60, 0.0, 1.00], [0.45, 7.6, 0.79], [0.35, 14.0, 0.65],
		[0.20, 24.6, 0.43], [0.10, 32.1, 0.29], [0.00, 40.0, 0.15],
	]
	for row: Array in expected:
		_zone(system).pressure = float(row[0])
		var service := system.get_water_service("B")
		assert_almost_eq(float(service["pressure"]), float(row[0]), 0.001)
		assert_almost_eq(float(service["happiness_penalty"]), float(row[1]), 0.05,
				"penalty at P = %.2f" % float(row[0]))
		assert_almost_eq(float(service["output_mult"]), float(row[2]), 0.005,
				"output mult at P = %.2f" % float(row[0]))


func test_upgrade_gate() -> void:
	# Example F's E_WATER_HEADROOM block, in miniature.
	var system := _rig({"pump_level": 2, "upstream_level": 2})
	_seed_zone(system, 30.0, 10.0, 5.0)
	system.attach_building("DC", Vector2i(11, 11), "data_center")
	system.set_demands({"DC": 21.0})
	_advance(system, H13, 240)
	var z := _zone(system)
	var headroom := system.zone_headroom_m3h("DC")
	assert_almost_eq(headroom, z.supply_m3h - z.demand_m3h, 0.001)
	var blocked := system.can_upgrade_water("DC", 32.0)
	assert_false(bool(blocked["ok"]), "delta 32.0 × 1.10 = 35.2 exceeds the headroom")
	assert_eq(String(blocked["reason"]), "BLOCKED_WATER_CAPACITY")
	assert_true(float(blocked["deficit_m3h"]) > 0.0)
	assert_true(bool(system.can_upgrade_water("DC", 1.0)["ok"]), "a small delta fits")


# --- test 23: the per-building hourly service factor (C-37) ---------------

func test_service_factor_hour() -> void:
	# §5.4's worked hour: 20.4 min at P 1.00, 21.0 min ramping (mean 0.70), 18.6
	# min dry → 0.585, and doc 03 then reads f_water = 0.45 + 0.55 × 0.585.
	var coarse := WaterServiceLedger.new(0.60)
	coarse.accumulate("H", 1.00, 0.08, 1.0, 20.4 / 60.0)
	coarse.accumulate("H", 0.42, 0.08, 1.0, 21.0 / 60.0)
	coarse.accumulate("H", 0.00, 0.08, 0.0, 18.6 / 60.0)
	coarse.settle_hour()
	assert_almost_eq(coarse.service_factor_hour("H"), 0.585, 0.005)
	assert_almost_eq(0.45 + 0.55 * coarse.service_factor_hour("H"), 0.772, 0.005,
			"doc 03's f_water for the hour the house half-lost water")
	# The identical figure at the fine cadence.
	var fine := WaterServiceLedger.new(0.60)
	for i in 204:
		fine.accumulate("H", 1.00, 0.08, 1.0, 0.1 / 60.0)
	for i in 210:
		fine.accumulate("H", 0.42, 0.08, 1.0, 0.1 / 60.0)
	for i in 186:
		fine.accumulate("H", 0.00, 0.08, 0.0, 0.1 / 60.0)
	fine.settle_hour()
	assert_almost_eq(fine.service_factor_hour("H"), coarse.service_factor_hour("H"), 0.001)
	# A save/load INSIDE the hour reproduces it exactly.
	var split := WaterServiceLedger.new(0.60)
	split.accumulate("H", 1.00, 0.08, 1.0, 20.4 / 60.0)
	var restored := WaterServiceLedger.new(0.60)
	restored.deserialize(split.serialize())
	restored.accumulate("H", 0.42, 0.08, 1.0, 21.0 / 60.0)
	restored.accumulate("H", 0.00, 0.08, 0.0, 18.6 / 60.0)
	restored.settle_hour()
	assert_almost_eq(restored.service_factor_hour("H"), 0.585, 0.005,
			"a mid-hour save can neither inflate nor erase the term")


func test_delivered_fraction_sibling() -> void:
	var ledger := WaterServiceLedger.new(0.60)
	ledger.accumulate("H", 1.0, 10.0, 1.0, 0.5)
	ledger.accumulate("H", 1.0, 10.0, 0.5, 0.5)
	ledger.settle_hour()
	assert_almost_eq(ledger.delivered_fraction_hour("H"), 0.75, 0.0001,
			"volumetric sibling: half an hour at half delivery")
	assert_almost_eq(ledger.service_factor_hour("H"), 1.0, 0.0001,
			"pressure was fine throughout — only the volume moved")


func test_service_factor_tracks_the_cascade() -> void:
	var system := _rig({"no_tank": true})
	system.attach_building("B", Vector2i(11, 12), "house")
	system.set_demands({"B": 0.08})
	_advance(system, H13, 240)
	var rng := RngStreams.new(11)
	system.hourly_step(rng)
	assert_almost_eq(system.water_service_factor_hour("B"), 1.0, 0.001)
	system.powered_provider = func(_ref: String) -> bool: return false
	_advance(system, H13, 240)
	system.hourly_step(rng)
	assert_true(system.water_service_factor_hour("B") < 0.2,
			"a dark pump with no tank empties the term inside one hour")


# --- test 25: scale invariance --------------------------------------------

func test_scale_invariance() -> void:
	# Re-run example A with every flow/volume constant divided back by
	# WU_SCALE 0.1333 — identical pressures, ratios and buffer hours.
	var k := 1.0 / 0.1333
	var scaled := WaterData.from_dict(_scaled_raw(k))
	assert_true(scaled.is_valid() or scaled.errors.size() == 5,
			"the scaled fixture only trips the doc-02 kW guard: %s" % str(scaled.errors))
	var native := _rig({"pump_condition": 0.95})
	_seed_zone(native, 16.0, 4.0, 1.6)
	native.advance(DT, H19)
	_set_tank(native, 108.0)
	native.powered_provider = func(_ref: String) -> bool: return false
	var big := _rig_with(scaled, {"pump_condition": 0.95})
	_seed_zone_scaled(big, 16.0 * k, 4.0 * k, 1.6 * k)
	big.advance(DT, H19)
	(big.node("TNK") as WaterNode).volume_m3 = 108.0 * k
	big.powered_provider = func(_ref: String) -> bool: return false
	for i in 240 * 3:
		native.advance(DT, H19)
		big.advance(DT, H19)
	var a := _zone(native)
	var b := _zone(big)
	assert_almost_eq(b.pressure, a.pressure, 1e-4, "pressure is scale-invariant")
	assert_almost_eq(b.ratio, a.ratio, 1e-4, "so is the delivered ratio")
	assert_almost_eq(b.level_frac(), a.level_frac(), 1e-4, "and the tank level")
	assert_almost_eq(b.tank_volume_m3 / k, a.tank_volume_m3, 1e-3)
	assert_almost_eq(b.demand_m3h / k, a.demand_m3h, 1e-3)


func _rig_with(data: WaterData, opts: Dictionary) -> WaterSystem:
	var system := WaterSystem.new(data, 64)
	system.add_node("SRC", &"source", Vector2i(10, 10), {"subtype": "river", "power_ref": "WTR"})
	system.add_node("TRT", &"treatment", Vector2i(10, 10), {"power_ref": "WTR"})
	system.add_node("PMP", &"pump", Vector2i(10, 10),
			{"condition": float(opts.get("pump_condition", 1.0)), "power_ref": "WTR"})
	system.add_node("TNK", &"tank", Vector2i(10, 14), {"power_ref": "WTR-TANK"})
	system.add_main("M1", [Vector2i(10, 10), Vector2i(10, 14)], {"tier": "trunk"})
	return system


func _seed_zone_scaled(system: WaterSystem, res: float, com: float, proc: float) -> void:
	_seed_zone(system, res, com, proc)


## Every flow / capacity / volume column × k; the shares, exponents, thresholds
## and rates are dimensionless and must NOT move.
func _scaled_raw(k: float) -> Dictionary:
	var raw := StarterCityLoader.read_json("res://data/water.json")
	var scale_columns := {
		"source_river": ["yield_m3h"], "source_well": ["yield_m3h"],
		"treatment": ["throughput_m3h"], "pump": ["rated_flow_m3h"],
		"tank": ["capacity_m3", "max_inflow_m3h", "max_outflow_m3h"],
		"booster": ["boost_flow_m3h"],
	}
	for key: String in scale_columns.keys():
		var columns: Array = raw["_component_columns"][key]
		var rows: Array = raw["components"][key]
		for row: Array in rows:
			for field: String in scale_columns[key]:
				var i: int = columns.find(field)
				row[i] = float(row[i]) * k
	for tier in ["service", "trunk", "arterial"]:
		raw["mains"][tier]["capacity_m3h"] = float(raw["mains"][tier]["capacity_m3h"]) * k
	raw["global"]["fire_flow_per_engine_m3h"] = \
			float(raw["global"]["fire_flow_per_engine_m3h"]) * k
	raw["repair"]["temp_supply_m3h"] = float(raw["repair"]["temp_supply_m3h"]) * k
	return raw
