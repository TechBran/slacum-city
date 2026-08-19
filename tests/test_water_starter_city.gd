extends SimTest
## Doc 05 §7 test 30 (the RR-11 guard) plus the founding-city acceptance run:
## doc 09 §2.9.6's authored topology, booted, ticked and cross-checked against
## the figures doc 09 §2.9.4 owns and doc 05 quotes.
##
## Every number asserted here is derived from the SHIPPED data — `data/
## buildings.json`'s water column, `data/time.json`'s two channels and
## `data/starter_city.json`'s manifest — so an edit to either doc's data fails
## this file loudly. That is exactly the stale-quote failure mode RR-11 exists
## to prevent (the withdrawn 8.2 m³/h / 4.9×).

const DT := 1.0 / 240.0
## Doc 09 §2.9.4's three reference hours, sampled at the top of the hour.
const HOUR_MEAN := -1.0


func _boot() -> Dictionary:
	var water_data := WaterData.from_dict(StarterCityLoader.read_json("res://data/water.json"))
	var loader := StarterCityLoader.new()
	loader.load_from(StarterCityLoader.read_json("res://data/starter_city.json"))
	var catalog := BuildingCatalog.new(
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"))
	var curves := DayCurveSet.new()
	curves.load_from(StarterCityLoader.read_json("res://data/time.json"))
	var system := WaterBoot.build(water_data, loader)
	WaterBoot.attach_buildings(system, loader)
	var buildings: Dictionary = {}
	for record in loader.buildings:
		var b := Building.new(int(record["grid_id"]), StringName(String(record["type"])),
				record["origin_global"], StringName(String(record.get("variant", ""))))
		b.level = int(record.get("level", 1))
		b.state = &"active"
		buildings[String(record["id"])] = b
	system.set_demands(WaterBoot.compose_demands(catalog, buildings))
	return {"system": system, "loader": loader, "catalog": catalog,
			"curves": curves, "buildings": buildings}


func _channels(curves: DayCurveSet, hour: float) -> Dictionary:
	return {
		"water_demand_residential": curves.channel_curve_value("water_demand_residential", hour),
		"water_demand_commercial": curves.channel_curve_value("water_demand_commercial", hour),
	}


func _advance(system: WaterSystem, channels: Dictionary, ticks: int) -> void:
	for i in ticks:
		system.advance(DT, channels)


# --- test 30: the RR-11 starter-headroom guard ----------------------------

func test_starter_headroom_reference() -> void:
	var rig := _boot()
	var system: WaterSystem = rig["system"]
	var catalog: BuildingCatalog = rig["catalog"]
	var loader: StarterCityLoader = rig["loader"]
	# Σ doc 02's water_demand over C-11's reverted 18/5/3/1 + 6 civic manifest.
	var total := 0.0
	var counts: Dictionary = {}
	for record in loader.buildings:
		var type_name := String(record["type"])
		counts[type_name] = int(counts.get(type_name, 0)) + 1
		total += float(catalog.stats(type_name, int(record.get("level", 1)))
				.get("water_demand", 0.0))
	assert_eq(int(counts.get("house", 0)), 18, "C-11's reverted manifest")
	assert_eq(int(counts.get("store", 0)), 5)
	assert_eq(int(counts.get("apartment", 0)), 3)
	assert_eq(int(counts.get("office", 0)), 1)
	assert_almost_eq(total, 5.56, 0.01,
			"18×0.08 + 3×0.48 + 5×0.13 + 1×0.32 + 0.19 + 0.40 + 0.96 + 0.16")
	# Against the single L1 duty pump.
	var pump_rated := float(system.data.component(&"pump", 1)["rated_flow_m3h"])
	assert_almost_eq(pump_rated, 40.0, 0.001)
	assert_almost_eq(pump_rated / total, 7.194, 0.02, "RR-11: 7.2× headroom, not 4.9×")
	# …and the quoted `_provenance` block must still match, to the digit.
	var reference: Dictionary = system.data.provenance["_starter_reference"]
	assert_almost_eq(float(reference["starter_demand_m3h_mean"]), total, 0.01,
			"the quoted figure has drifted from doc 09's manifest")
	assert_almost_eq(float(reference["starter_supply_m3h"]), pump_rated, 0.001)
	assert_almost_eq(float(reference["starter_headroom_x"]), pump_rated / total, 0.05)


func test_starter_demand_at_the_three_reference_hours() -> void:
	var rig := _boot()
	var system: WaterSystem = rig["system"]
	var curves: DayCurveSet = rig["curves"]
	# Doc 09 §2.9.6: mean 5.56, 07:00 peak 7.10, 20:00 6.24 — reproduced from
	# the demand_split table against data/time.json's authored channels.
	system.advance(DT, _channels(curves, 7.0))
	assert_almost_eq(system.topology.zones[0].demand_m3h, 7.10, 0.02,
			"07:00 morning peak (doc 09 §2.9.6)")
	system.advance(DT, _channels(curves, 20.0))
	assert_almost_eq(system.topology.zones[0].demand_m3h, 6.24, 0.02, "20:00 night draw")
	system.advance(DT, {"water_demand_residential": 1.0, "water_demand_commercial": 1.0})
	assert_almost_eq(system.topology.zones[0].demand_m3h, 5.56, 0.01,
			"the 24-hour mean, with both channels at 1.0")
	var z: PressureZone = system.topology.zones[0]
	assert_almost_eq(z.res_base, 2.7072, 0.001, "18 houses + 3 apartments × share 0.88")
	assert_almost_eq(z.com_base, 1.0323, 0.001)
	assert_almost_eq(z.proc_base, 1.8205, 0.001)


func test_starter_tank_autonomy() -> void:
	var rig := _boot()
	var system: WaterSystem = rig["system"]
	var curves: DayCurveSet = rig["curves"]
	system.advance(DT, {"water_demand_residential": 1.0, "water_demand_commercial": 1.0})
	var z: PressureZone = system.topology.zones[0]
	var tank_capacity := float(system.data.component(&"tank", 1)["capacity_m3"])
	assert_almost_eq(tank_capacity, 120.0, 0.001)
	assert_almost_eq(tank_capacity / z.demand_m3h, 21.58, 0.1,
			"doc 09 §2.9.6: 21.6 game-hours on the daily mean")
	system.advance(DT, _channels(curves, 7.0))
	assert_almost_eq(tank_capacity / system.topology.zones[0].demand_m3h, 16.9, 0.1,
			"…16.9 gh at the morning peak")
	# Night + two engines flowing on a fire cuts the buffer to 5.4 gh — the
	# coupling doc 09 says is the real drama, not the clock.
	system.register_fire_engines("FIRE-1", Vector2i(40, 40), 2)
	system.advance(DT, _channels(curves, 20.0))
	assert_almost_eq(system.topology.zones[0].demand_m3h, 22.24, 0.05, "6.24 + 2 × 8.0")
	assert_almost_eq(tank_capacity / system.topology.zones[0].demand_m3h, 5.40, 0.05)


# --- acceptance: the founding city is fully served ------------------------

func test_starter_city_is_fully_served() -> void:
	var rig := _boot()
	var system: WaterSystem = rig["system"]
	var loader: StarterCityLoader = rig["loader"]
	var curves: DayCurveSet = rig["curves"]
	_advance(system, _channels(curves, 7.0), 240)
	assert_eq(system.topology.zones.size(), 1,
			"doc 09 §2.9.6: the looped mains put the whole core in one zone Z1")
	var z: PressureZone = system.topology.zones[0]
	assert_eq(z.zone_key, "WTR-1-PMP", "zone_key = smallest facility node id")
	assert_false(z.dead)
	assert_almost_eq(z.upstream_cap_m3h, 80.0, 0.001, "min(source 107, treatment 80)")
	assert_almost_eq(z.supply_m3h, 40.0, 0.001, "one L1 duty pump at full condition")
	assert_almost_eq(z.ratio, 1.0, 1e-9)
	assert_almost_eq(z.pressure, 1.0, 1e-6, "P = 1.0 across the founding city")
	assert_true(z.feed_capacity_m3h >= z.supply_m3h,
			"the min-cut does not bite at 7.2× headroom")
	assert_almost_eq(system.water_health_pct(), 100.0, 0.001, "HUD reads Water: 100%")
	assert_almost_eq(system.water_margin_score(), 1.0, 1e-9)
	# Every authored building is attached to the live zone and wet.
	var below_nominal: Array = []
	for record in loader.buildings:
		var id := String(record["id"])
		var tile: Vector2i = record["origin_global"]
		assert_eq(system.topology.zone_at_tile(tile), 0, "%s is unserved" % id)
		var pressure := system.pressure_at(tile)
		assert_true(pressure > 0.0, "%s reads zero pressure" % id)
		var service := system.get_water_service(id)
		assert_ne(String(service["band"]), "critical", "%s is in the critical band" % id)
		assert_ne(String(service["band"]), "none", "%s has no water" % id)
		if pressure < 0.60:
			below_nominal.append(id)
	# FINDING (for the overseer): doc 09's laterals stop at each block's centre,
	# so `prox` falls to 0.60 at the northern lot line and one house sits at
	# 0.50. Every other building is at or above the 0.60 nominal, i.e. a full
	# `water_service_factor_hour`. Fix is doc 09's (extend the laterals along the
	# z = 7/23/39 STREETs) or doc 05's (`prox_falloff_per_tile`), not code.
	assert_eq(below_nominal, ["H-003"],
			"exactly one starter building sits below the 0.60 nominal pressure")
	assert_almost_eq(system.pressure_at(Vector2i(46, 33)), 0.50, 0.001,
			"H-003 at global (46,33) is 7 tiles from the nearest live main")


func test_starter_service_factors_after_one_hour() -> void:
	var rig := _boot()
	var system: WaterSystem = rig["system"]
	var loader: StarterCityLoader = rig["loader"]
	var curves: DayCurveSet = rig["curves"]
	_advance(system, _channels(curves, 7.0), 240)
	system.hourly_step(RngStreams.new(1337))
	var worst := 1.0
	for record in loader.buildings:
		var id := String(record["id"])
		var factor := system.water_service_factor_hour(id)
		worst = minf(worst, factor)
		assert_true(factor >= 0.83, "%s billed only %.3f of its water term" % [id, factor])
	assert_almost_eq(worst, 5.0 / 6.0, 0.005, "H-003's clamp(0.50 / 0.60)")
	assert_almost_eq(system.water_service_factor_hour("H-014"), 1.0, 1e-6,
			"a building on the main bills its full water term")
	# Doc 03's `f_water` for a residential building at the worst tile.
	assert_almost_eq(0.45 + 0.55 * worst, 0.908, 0.005)


func test_starter_inventory_feeds_e_water() -> void:
	var rig := _boot()
	var system: WaterSystem = rig["system"]
	var curves: DayCurveSet = rig["curves"]
	_advance(system, {"water_demand_residential": 1.0, "water_demand_commercial": 1.0}, 240)
	system.hourly_step(RngStreams.new(5))
	var inventory := system.inventory()
	assert_almost_eq(float(inventory["pump_capacity_m3h"]), 40.0, 0.001,
			"doc 03 §2.12(d): 40 × 0.35 = $14/gh of pump O&M (RR-6)")
	assert_almost_eq(float(inventory["m3_treated"]), 5.56, 0.02,
			"one game-hour of delivered volume at the daily mean")
	assert_almost_eq(float(inventory["delivered_m3"]), 5.56, 0.02)
	assert_almost_eq(float(inventory["main_condition"]), 1.0, 0.001)
	# FINDING: doc 03 §2.12 bills 1.512 km (126 trunk + 9×7 lateral). The
	# authored laterals are 9/9/9/7/7/7/7/7/7 = 69 tiles, not 63, so the live
	# figure is 1.560 km. Doc 03's ledger line moves $1.058 → $1.092/gh.
	assert_almost_eq(float(inventory["main_km"]), 1.560, 0.001,
			"126 trunk + 69 lateral tiles × 8 m")


# --- the headline cascade -------------------------------------------------

func test_losing_f_south_stops_the_starter_water_works() -> void:
	# Doc 09 §2.9.6: `coverage_frac = 0.00` at L1 across the board, so the
	# starter water works has NO generator. Losing `F_SOUTH` stops it dead.
	var rig := _boot()
	var system: WaterSystem = rig["system"]
	var curves: DayCurveSet = rig["curves"]
	var channels := _channels(curves, 20.0)
	_advance(system, channels, 240)
	assert_almost_eq(system.topology.zones[0].supply_m3h, 40.0, 0.001)
	system.powered_provider = func(power_ref: String) -> bool:
		return power_ref != "WTR-1" and power_ref != "WTR-2"
	system.advance(DT, channels)
	assert_almost_eq(system.topology.zones[0].supply_m3h, 0.0, 1e-9,
			"no backup module at L1 — the pump trips immediately")
	assert_almost_eq((system.node("WTR-1-PMP") as WaterNode).restart_timer_min, 5.0, 1e-9)
	# 120 m³ against a 6.24 m³/h night draw ≈ 19 game-hours of buffer, and the
	# city does not notice for hours: P stays 1.0 while the tank pays.
	_advance(system, channels, 240 * 4)
	assert_almost_eq(system.topology.zones[0].pressure, 1.0, 0.001,
			"four hours in and nothing is visibly wrong — the tank is the story")
	var z: PressureZone = system.topology.zones[0]
	assert_almost_eq(z.tank_volume_m3, 120.0 - 6.24 * 4.0, 0.3)
	assert_almost_eq(z.buffer_hours(), z.tank_volume_m3 / 6.24, 0.05)
	# Power returns: 5 game-minutes of restart lockout, then the tank refills.
	var lowest := z.tank_volume_m3
	system.powered_provider = Callable()
	_advance(system, channels, 240)
	assert_true(z.tank_volume_m3 > lowest, "the tank refills once the pump restarts")
	# The 33.76 m³/h surplus is NOT the refill rate — the L1 tank's
	# `max_inflow_m3h` of 26.5 is, which is §2.7's "refill is slower than drain"
	# lesson. 55.25 min of inflow minus 4.75 min of lockout drain.
	assert_almost_eq(z.tank_volume_m3 - lowest,
			26.5 * (55.25 / 60.0) - 6.24 * (4.75 / 60.0), 0.05)


func test_fire_during_an_outage_drains_the_tank_five_times_faster() -> void:
	var rig := _boot()
	var system: WaterSystem = rig["system"]
	var curves: DayCurveSet = rig["curves"]
	var channels := _channels(curves, 20.0)
	_advance(system, channels, 240)
	system.powered_provider = func(power_ref: String) -> bool:
		return power_ref != "WTR-1" and power_ref != "WTR-2"
	system.register_fire_engines("FIRE-1", Vector2i(56, 39), 2)
	_advance(system, channels, 240)
	var z: PressureZone = system.topology.zones[0]
	assert_almost_eq(z.fire_draw_m3h, 16.0, 0.001)
	assert_almost_eq(120.0 - z.tank_volume_m3, 22.24, 0.3,
			"one hour of night draw + two engines = 22.24 m³ out of the tank")
	assert_true(z.buffer_hours() < 5.5, "the buffer collapses from 19 gh to ~4.4 gh")


# --- determinism and persistence on the real city -------------------------

func test_starter_city_determinism() -> void:
	var a := _boot()["system"] as WaterSystem
	var b := _boot()["system"] as WaterSystem
	var channels := {"water_demand_residential": 1.0, "water_demand_commercial": 1.0}
	for h in 24:
		for i in 240:
			a.advance(DT, channels)
			b.advance(DT, channels)
		a.hourly_step(RngStreams.new(1337 + h))
		b.hourly_step(RngStreams.new(1337 + h))
	assert_eq(JSON.stringify(CitySim._encode_floats(b.serialize())),
			JSON.stringify(CitySim._encode_floats(a.serialize())),
			"24 game-hours of the starter city capture bit-identically")


func test_starter_city_save_roundtrip() -> void:
	var rig := _boot()
	var system: WaterSystem = rig["system"]
	var curves: DayCurveSet = rig["curves"]
	var channels := _channels(curves, 13.0)
	for h in 6:
		_advance(system, channels, 240)
		system.hourly_step(RngStreams.new(88 + h))
	system.set_segment_broken("M_NORTH", 0.55, "INC-9", -0.35)
	_advance(system, channels, 120)
	var saved := JSON.stringify(CitySim._encode_floats(system.serialize()))
	var restored := WaterSystem.new(
			WaterData.from_dict(StarterCityLoader.read_json("res://data/water.json")),
			TileGrid.SIZE)
	restored.terrain = system.terrain
	restored.deserialize(CitySim._decode_floats(JSON.parse_string(saved)))
	assert_eq(restored.topology.zones.size(), 1)
	assert_eq(restored.topology.zones[0].zone_key, "WTR-1-PMP")
	assert_almost_eq(restored.topology.zones[0].pressure,
			system.topology.zones[0].pressure, 1e-9)
	assert_almost_eq(restored.topology.zones[0].tank_volume_m3,
			system.topology.zones[0].tank_volume_m3, 1e-9)
	assert_eq(String(restored.edge("M_NORTH").state), "broken")
	# The junction ladder is persisted, so zone keys cannot drift after a load.
	assert_eq(restored.nodes.size(), system.nodes.size())
	for i in 240:
		system.advance(DT, channels)
		restored.advance(DT, channels)
	assert_eq(JSON.stringify(CitySim._encode_floats(restored.serialize())),
			JSON.stringify(CitySim._encode_floats(system.serialize())),
			"a loaded starter city continues in lockstep with the one that saved")


func test_zone_covers_the_whole_core() -> void:
	# Doc 09 §2.9.6: `max_service_distance_tiles = 12` from a live main tile
	# covers all 2,304 core tiles.
	var system := _boot()["system"] as WaterSystem
	var covered := 0
	for z in range(StarterCityLoader.CORE_TILE_OFFSET,
			StarterCityLoader.CORE_TILE_OFFSET + StarterCityLoader.CORE_TILES):
		for x in range(StarterCityLoader.CORE_TILE_OFFSET,
				StarterCityLoader.CORE_TILE_OFFSET + StarterCityLoader.CORE_TILES):
			if system.topology.zone_at_tile(Vector2i(x, z)) == 0:
				covered += 1
	assert_eq(covered, 2304, "every core tile is inside zone Z1")


func test_overlay_snapshot_on_the_real_city() -> void:
	var rig := _boot()
	var system: WaterSystem = rig["system"]
	var curves: DayCurveSet = rig["curves"]
	_advance(system, _channels(curves, 7.0), 240)
	var snapshot := system.get_overlay_snapshot()
	assert_eq((snapshot["zones"] as Array).size(), 1)
	assert_eq(String((snapshot["zones"][0] as Dictionary)["color_band"]), "normal")
	assert_eq((snapshot["nodes"] as Array).size(), 4, "SRC + TRT + PMP + tank")
	assert_eq((snapshot["edges"] as Array).size(), 13, "4 mains + 9 laterals")
	assert_almost_eq(float(snapshot["city"]["water_health_pct"]), 100.0, 0.001)
	assert_almost_eq(float(snapshot["city"]["total_storage_m3"]), 120.0, 0.5)
	assert_eq(int(snapshot["city"]["zones_in_deficit"]), 0)
	# The three powered nodes publish doc 04's sink ratings: 32 + 40 + 60 = 132 kW.
	var site_kw := 0.0
	for row: Dictionary in snapshot["nodes"]:
		if String(row["id"]).begins_with("WTR-1"):
			site_kw += float(row["load_kw"])
	assert_almost_eq(site_kw, 132.0, 0.001, "doc 09 §2.9.6's WTR-1 site load")
