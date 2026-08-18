extends SimTest
## Doc 09 §2.6: district stability (worked values), district_dark aggregation,
## city_stability weighting, EMAs, auto-assignment and reassignment rules.


func _world_with_core() -> WorldMap:
	var world := WorldMap.new()
	for bz in 7:
		for bx in 7:
			var owned: bool = bx >= 2 and bx <= 4 and bz >= 2 and bz <= 4
			world.add_block(LandBlock.from_dict({
				"id": WorldMap.block_id_for(bx, bz), "grid": [bx, bz],
				"terrain_class": "flat", "road_access": "ARTERIAL",
				"ownership_state": "OWNED" if owned else "LOCKED",
				"development_state": "READY" if owned else "UNDEVELOPED",
			}))
	return world


func _registry(world: WorldMap = null) -> DistrictRegistry:
	if world == null:
		world = _world_with_core()
	return DistrictRegistry.new(world, RngStreams.new(42), ["Northgate", "Downtown", "Riverside"])


func test_downtown_stability_worked_values() -> void:
	var registry := _registry()
	var id := registry.create_district(["B_3_3", "B_4_3"])
	registry.set_population_jobs(id, 24, 60)
	registry.set_indices(id, 0.10, 0.12, 0.0)
	# t0: reliabilities 1.00, ARTERIAL frontage → doc 09 §2.6: 0.974
	assert_almost_eq(registry.recompute_fast(id), 0.974, 0.0005)
	# 3 gh into the F_SOUTH fault → 0.7335
	var d := registry.district(id)
	d["power_reliability"] = 0.55
	d["water_reliability"] = 0.70
	registry.set_indices(id, 0.28, 0.31, 0.0)
	assert_almost_eq(registry.recompute_fast(id), 0.7335, 0.0005)


func test_northgate_employment_shortfall() -> void:
	var registry := _registry()
	var id := registry.create_district(["B_2_2", "B_3_2", "B_4_2"])
	registry.set_population_jobs(id, 100, 34)
	registry.set_indices(id, 0.10, 0.12, 0.0)
	# employment_ratio = 34 / 55 = 0.6182 → stability 0.9358 (doc 09 §2.6)
	assert_almost_eq(registry.recompute_fast(id), 0.9358, 0.0005)


func test_city_stability_population_weighted() -> void:
	var registry := _registry()
	var north := registry.create_district(["B_2_2"])
	var down := registry.create_district(["B_3_3"])
	var east := registry.create_district(["B_4_4"])
	var south := registry.create_district(["B_2_4"])
	registry.set_population_jobs(north, 100, 34)
	registry.set_population_jobs(down, 24, 60)
	registry.set_population_jobs(east, 16, 10)
	registry.set_population_jobs(south, 4, 2)
	registry.district(north)["stability"] = 0.9358
	registry.district(down)["stability"] = 0.9740
	registry.district(east)["stability"] = 0.9740
	registry.district(south)["stability"] = 0.9740
	# Doc 09 §2.6: (100×0.9358 + 24×0.974 + 16×0.974 + 4×0.974) / 144 = 0.9475
	assert_almost_eq(registry.recompute_slow(), 0.9475, 0.0005)
	# F_SOUTH: only Downtown degraded → city scalar moves just 0.040
	registry.district(down)["stability"] = 0.7335
	assert_almost_eq(registry.recompute_slow(), 0.9074, 0.0005)


func test_district_dark_weighted_and_fallback() -> void:
	var registry := _registry()
	var id := registry.create_district(["B_3_3", "B_4_3"])
	# Population-weighted: 100 of 100 residents dark → fraction 1.0, dark.
	registry.update_district_dark(id, {"B_3_3": true, "B_4_3": false}, {"B_3_3": 100, "B_4_3": 0})
	assert_almost_eq(registry.district(id)["district_dark_fraction"], 1.0, 1e-9)
	assert_true(bool(registry.district(id)["district_dark"]))
	# Minority dark by population → below the 0.60 threshold.
	registry.update_district_dark(id, {"B_3_3": true, "B_4_3": false}, {"B_3_3": 40, "B_4_3": 100})
	assert_almost_eq(registry.district(id)["district_dark_fraction"], 40.0 / 140.0, 1e-6)
	assert_false(bool(registry.district(id)["district_dark"]))
	# Zero-population fallback (pure utility blocks): mean over member blocks.
	registry.update_district_dark(id, {"B_3_3": true, "B_4_3": false}, {})
	assert_almost_eq(registry.district(id)["district_dark_fraction"], 0.5, 1e-9)
	assert_false(bool(registry.district(id)["district_dark"]))
	registry.update_district_dark(id, {"B_3_3": true, "B_4_3": true}, {})
	assert_true(bool(registry.district(id)["district_dark"]))


func test_reliability_ema_halflife() -> void:
	var registry := _registry()
	var id := registry.create_district(["B_3_3"])
	# Halflife 6 gh: one 6-hour step at ratio 0 takes the EMA from 1.0 to 0.5.
	registry.update_power_reliability(id, 0.0, 6.0)
	assert_almost_eq(registry.district(id)["power_reliability"], 0.5, 1e-9)
	registry.update_power_reliability(id, 0.0, 6.0)
	assert_almost_eq(registry.district(id)["power_reliability"], 0.25, 1e-9)


func test_apply_stability_offset_and_decay() -> void:
	var registry := _registry()
	var id := registry.create_district(["B_3_3"])
	registry.set_population_jobs(id, 10, 20)
	registry.set_indices(id, 0.0, 0.0, 0.0)
	var base := registry.recompute_fast(id)
	registry.apply_stability(id, -0.2)
	assert_almost_eq(registry.recompute_fast(id), base - 0.2, 1e-9)
	registry.recompute_slow(6.0)  # offset halflife 6 gh
	assert_almost_eq(registry.recompute_fast(id), base - 0.1, 1e-9)


func test_auto_assign_prefers_same_terrain_then_smallest() -> void:
	var world := _world_with_core()
	world.block("B_2_2").terrain_class = &"hills"
	var registry := _registry(world)
	var hills := registry.create_district(["B_2_2"])
	var flat := registry.create_district(["B_2_4", "B_2_3"])
	# B_3_2 (flat) is adjacent to hills district (via B_2_2)? No — B_3_2 is
	# adjacent to B_2_2 (west), B_4_2, B_3_3. Make it adjacent to both districts:
	# B_2_3 belongs to `flat` and is adjacent to B_2_2... use B_3_2's real
	# neighbours: only `hills` qualifies via B_2_2.
	var joined := registry.auto_assign("B_3_2")
	assert_eq(joined, hills, "only adjacent district joins despite terrain mismatch")
	# B_3_3 is adjacent to B_3_2 (now hills district, size 2) and B_2_3/B_3_4…
	# `flat` is adjacent via B_2_3? B_3_3's neighbours: B_2_3 (flat district),
	# B_4_3 (none), B_3_2 (hills district), B_3_4 (none). flat matches terrain
	# and wins over the size-2 mismatch even though both have room.
	var joined2 := registry.auto_assign("B_3_3")
	assert_eq(joined2, flat, "same-terrain district preferred")


func test_auto_assign_creates_when_full_or_isolated() -> void:
	var registry := _registry()
	var d1 := registry.create_district(["B_2_2", "B_3_2", "B_4_2", "B_2_3"])
	var created := registry.auto_assign("B_3_3")
	assert_ne(created, d1, "size-4 district cannot grow; a new district is created")
	assert_eq((registry.district(created)["blocks"] as Array), ["B_3_3"])


func test_manual_reassignment_rules() -> void:
	var registry := _registry()
	var a := registry.create_district(["B_2_2", "B_3_2"])
	var b := registry.create_district(["B_3_3"])
	# Contiguity: B_2_2 does not touch B_3_3.
	assert_eq(registry.assign_block_to_district("B_2_2", b, 0)["reason_code"], &"E_NOT_CONTIGUOUS")
	# Legal move: B_3_2 touches B_3_3.
	assert_true(bool(registry.assign_block_to_district("B_3_2", b, 0)["ok"]))
	assert_eq(registry.district_of_block("B_3_2"), b)
	# Cooldown: 24 game-hours per block.
	var back := registry.assign_block_to_district("B_3_2", a, 100)
	assert_eq(back["reason_code"], &"E_REASSIGN_COOLDOWN")
	assert_true(bool(registry.assign_block_to_district("B_3_2", a, 1441)["ok"]))


func test_registry_serialize_roundtrip() -> void:
	var registry := _registry()
	var id := registry.create_district(["B_3_3", "B_4_3"], "Downtown")
	registry.set_population_jobs(id, 24, 60)
	registry.set_indices(id, 0.10, 0.12, 0.0)
	registry.recompute_fast(id)
	registry.recompute_slow()
	var restored := _registry()
	restored.deserialize(registry.serialize())
	assert_eq(restored.district(id)["name"], "Downtown")
	assert_almost_eq(restored.district(id)["stability"], registry.district(id)["stability"], 1e-9)
	assert_almost_eq(restored.city_stability, registry.city_stability, 1e-9)
	# New districts after load must not collide with existing ids.
	var next_id := restored.create_district(["B_2_2"])
	assert_ne(next_id, id)
