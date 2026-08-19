extends SimTest
## The doc 05 → CitySim integration contract, exercised against a LIVE
## `CitySim` so the adapter in the delivery report is proven code rather than a
## proposal. The two inner classes below are exactly the `PhaseSystem` pair the
## lead engineer drops into `sim/city_sim.gd`.
##
## Doc 01 orders **P06 POWER → P07 WATER** in the same step (a pump that loses
## its feeder loses pressure with zero lag), and inside P07 the every-tick
## system sorts before the hourly one because systems in a phase are ordered by
## `system_id` — `"water"` < `"water_hourly"`.


class WaterPhaseSystem extends SimSystem:
	var sim: CitySim
	var water: WaterSystem
	func _init(p_sim: CitySim, p_water: WaterSystem) -> void:
		sim = p_sim
		water = p_water
	func system_id() -> StringName: return &"water"
	func phase() -> int: return Phase.WATER
	func cadence() -> int: return Cadence.EVERY_TICK
	func advance_fine(ctx: TimeContext) -> void:
		water.set_demands(compose_water_demands(sim))
		water.advance(float(ctx.dt_game_seconds) / 3600.0, ctx.channels)
	func advance_coarse(ctx: TimeContext) -> void:
		advance_fine(ctx)

	## Doc 02 §2.5's published `W_b`: the magnitude × `STATE_DEMAND[state]` ×
	## doc 07's `water_mult` (1.0 in the clear-sky stub). Doc 05 owns only the
	## res/com/proc split it is routed through.
	static func compose_water_demands(s: CitySim) -> Dictionary:
		var out: Dictionary = {}
		var ids := s.buildings.keys()
		ids.sort()
		for id in ids:
			var b: Building = s.buildings[id]
			out[id] = float(b.stats.get("water_demand", 0.0)) * b.water_demand_mult()
		return out


class WaterHourlySystem extends SimSystem:
	var sim: CitySim
	var water: WaterSystem
	func _init(p_sim: CitySim, p_water: WaterSystem) -> void:
		sim = p_sim
		water = p_water
	func system_id() -> StringName: return &"water_hourly"
	func phase() -> int: return Phase.WATER
	func cadence() -> int: return Cadence.EVERY_HOUR
	func advance_fine(_ctx: TimeContext) -> void:
		water.hourly_step(sim.rng, {"weather_kind": "clear", "air_temp_c": 22.0})
	func advance_coarse(ctx: TimeContext) -> void:
		advance_fine(ctx)


func _wire(sim: CitySim) -> WaterSystem:
	var water_data := WaterData.from_dict(StarterCityLoader.read_json("res://data/water.json"))
	var water := WaterBoot.build(water_data, sim.loader, sim.world.grid)
	# §2.6: water reads power ONLY through doc 04's published function.
	water.powered_provider = func(power_ref: String) -> bool:
		return sim.grid.is_powered(power_ref)
	WaterBoot.attach_buildings(water, sim.loader)
	water.rebuild_zones()
	sim.scheduler.register(WaterPhaseSystem.new(sim, water))
	sim.scheduler.register(WaterHourlySystem.new(sim, water))
	return water


func test_integration_with_city_sim() -> void:
	var sim := CitySim.boot_from_files(1337)
	assert_true(sim.boot_errors.is_empty(), "CitySim boots: %s" % str(sim.boot_errors))
	var water := _wire(sim)
	sim.advance_hours(24.0)
	assert_eq(water.topology.zones.size(), 1)
	var z: PressureZone = water.topology.zones[0]
	# 40.0 × cond_factor: 24 game-hours of §2.12 maintenance decay at full
	# funding takes the pump from 1.0000 to 0.9976, i.e. 39.952 m³/h.
	var pump: WaterNode = water.node("WTR-1-PMP")
	assert_almost_eq(pump.condition, 1.0 - 24.0 * 0.0001, 1e-9, "one day of decay")
	assert_almost_eq(z.supply_m3h, 40.0 * pump.cond_factor(), 0.001,
			"the duty pump ran all day")
	assert_almost_eq(z.pressure, 1.0, 1e-6)
	assert_true(z.demand_m3h > 5.0 and z.demand_m3h < 8.0,
			"the live demand tracks doc 01's channels: %.3f m³/h" % z.demand_m3h)
	# Doc 03's `w_b` per building — the value that replaces the `"water": 1.0`
	# stub in `build_settlement_inputs`.
	var factors := water.service_factors()
	assert_eq(factors.size(), sim.buildings.size(),
			"every CitySim building settles a water term")
	for id in factors:
		assert_true(float(factors[id]) >= 0.83, "%s billed %.3f" % [id, float(factors[id])])
	# …and the `E_water` inputs doc 03 bills against, replacing HELD_WATER.
	var inventory := water.inventory()
	assert_almost_eq(float(inventory["pump_capacity_m3h"]), 40.0, 0.001)
	assert_true(float(inventory["m3_treated"]) > 0.0)
	assert_almost_eq(float(inventory["main_km"]), 1.560, 0.001)
	# The site's doc-04 sink rating, which replaces CitySim.WATER_VARIANT_KW_L1.
	var site_kw := 0.0
	var node_ids := water.nodes.keys()
	node_ids.sort()
	for node_id in node_ids:
		var n: WaterNode = water.nodes[node_id]
		if n.power_ref == "WTR-1":
			site_kw += water.data.kw_required(n.variant, n.level, n.subtype)
	assert_almost_eq(site_kw, 132.0, 0.001,
			"32 + 40 + 60 — the figure CitySim.WATER_VARIANT_KW_L1 holds today")


func test_integration_power_cascade_through_the_grid() -> void:
	var sim := CitySim.boot_from_files(1337)
	var water := _wire(sim)
	sim.advance_hours(2.0)
	var pump: WaterNode = water.node("WTR-1-PMP")
	assert_almost_eq(water.topology.zones[0].supply_m3h, 40.0 * pump.cond_factor(), 0.001)
	assert_true(sim.grid.is_powered("WTR-1"))
	# Doc 09 §2.9.5's designed lesson: `F_SOUTH` carries the water works and
	# there is no tie switch at t0.
	sim.grid.force_open("F_SOUTH")
	sim.advance_hours(1.0)
	assert_false(sim.grid.is_powered("WTR-1"), "the feeder fault darkens the water works")
	assert_almost_eq(water.topology.zones[0].supply_m3h, 0.0, 1e-9,
			"…and the pump trips: no L1 backup module (coverage_frac 0.00)")
	assert_true(water.topology.zones[0].tank_volume_m3 < 120.0, "the tank is paying")
	assert_almost_eq(water.topology.zones[0].pressure, 1.0, 0.001,
			"nothing is visibly wrong yet — 120 m³ against a ~6 m³/h draw")
	# Restore the feeder and the pump picks up after its 5-minute lockout.
	sim.grid.force_close("F_SOUTH")
	sim.advance_hours(1.0)
	assert_almost_eq(water.topology.zones[0].supply_m3h, 40.0 * pump.cond_factor(), 0.001)


func test_integration_upgrade_gate_and_placement() -> void:
	var sim := CitySim.boot_from_files(1337)
	var water := _wire(sim)
	sim.advance_hours(1.0)
	# Doc 02's check E_WATER_HEADROOM, against the live zone.
	var b: Building = sim.buildings["H-014"]
	var next_stats := sim.catalog.stats(String(b.archetype), b.level + 1)
	var delta_water := float(next_stats.get("water_demand", 0.0)) \
			- float(b.stats.get("water_demand", 0.0))
	assert_true(delta_water > 0.0, "doc 02's water column rises with level")
	var gate := water.can_upgrade_water("H-014", delta_water)
	assert_true(bool(gate["ok"]), "7.2× headroom clears an L1 → L2 house")
	var blocked := water.can_upgrade_water("H-014", 100.0)
	assert_false(bool(blocked["ok"]))
	assert_eq(String(blocked["reason"]), "BLOCKED_WATER_CAPACITY")
	# A newly placed building joins the demand cache without a tile BFS.
	var placed := sim.cmd_place_building("house", Vector2i(38, 34))
	assert_true(bool(placed["ok"]), "placement: %s" % str(placed))
	var sim_id := String(placed["payload"]["sim_id"])
	water.attach_building(sim_id, Vector2i(38, 34), "house")
	assert_false(water.topology_dirty, "attaching a building is not a topology change")
	sim.advance_hours(1.0)
	assert_true(water.topology.zones[0].building_count >= sim.buildings.size() - 1)
	assert_true(water.pressure_at(Vector2i(38, 34)) > 0.0, "the new lot is served")


func test_integration_save_section_survives_city_sim_encoding() -> void:
	# The water section rides inside CitySim's save body, so it has to survive
	# `_encode_floats` → JSON → `_decode_floats` unchanged.
	var sim := CitySim.boot_from_files(1337)
	var water := _wire(sim)
	sim.advance_hours(6.0)
	water.set_segment_broken("M_SOUTH", 0.7, "INC-1", -0.35)
	sim.advance_hours(1.0)
	var body := {"city": sim.capture_state(), "water": water.serialize()}
	var text := JSON.stringify(CitySim._encode_floats(body), "", true, true)
	var round_tripped: Dictionary = CitySim._decode_floats(JSON.parse_string(text))
	var restored := WaterSystem.new(
			WaterData.from_dict(StarterCityLoader.read_json("res://data/water.json")),
			TileGrid.SIZE)
	restored.terrain = sim.world.grid
	restored.deserialize(round_tripped["water"])
	assert_eq(JSON.stringify(CitySim._encode_floats(restored.serialize())),
			JSON.stringify(CitySim._encode_floats(water.serialize())),
			"the water section round-trips bit-exactly through CitySim's encoder")
	assert_almost_eq(restored.edge("M_SOUTH").incident_pressure_penalty, 0.35, 1e-9,
			"the doc-06 penalty survives — it is stored as a magnitude because "
			+ "CitySim._encode_floats corrupts negative floats (see the report)")
