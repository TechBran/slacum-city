extends SimTest
## Doc 09 P0-10: TileGrid, LandBlock, WorldMap core — geometry, derived
## attributes (against doc 09's own worked values), and the adjacency rule.


func test_block_of_geometry() -> void:
	assert_eq(TileGrid.block_of(0, 0), Vector2i(0, 0))
	assert_eq(TileGrid.block_of(15, 15), Vector2i(0, 0))
	assert_eq(TileGrid.block_of(16, 15), Vector2i(1, 0))
	assert_eq(TileGrid.block_of(32, 32), Vector2i(2, 2), "core origin")
	assert_eq(TileGrid.block_of(56, 56), Vector2i(3, 3), "city centre tile is in B_3_3")
	assert_eq(TileGrid.block_of(111, 111), Vector2i(6, 6))
	assert_true(TileGrid.in_bounds(0, 0))
	assert_true(TileGrid.in_bounds(111, 111))
	assert_false(TileGrid.in_bounds(112, 0))
	assert_false(TileGrid.in_bounds(0, -1))


func test_flags_and_roads() -> void:
	var grid := TileGrid.new()
	grid.set_flag(5, 5, TileGrid.FLAG_BUILDABLE)
	assert_true(grid.has_flag(5, 5, TileGrid.FLAG_BUILDABLE))
	assert_false(grid.has_flag(5, 5, TileGrid.FLAG_ROAD))
	grid.set_road(5, 5, TileGrid.ROAD_AVENUE)
	assert_true(grid.has_flag(5, 5, TileGrid.FLAG_ROAD))
	assert_false(grid.has_flag(5, 5, TileGrid.FLAG_BUILDABLE), "road tiles are not buildable")
	assert_eq(grid.road_class_at(5, 5), TileGrid.ROAD_AVENUE)
	grid.set_road(5, 5, TileGrid.ROAD_NONE)
	assert_false(grid.has_flag(5, 5, TileGrid.FLAG_ROAD))


func test_building_stamp_and_overlap() -> void:
	var grid := TileGrid.new()
	for z in range(0, 16):
		for x in range(0, 16):
			grid.set_flag(x, z, TileGrid.FLAG_BUILDABLE)
	assert_true(grid.stamp_building(7, Vector2i(2, 2), Vector2i(3, 3)))
	assert_eq(grid.building_at(3, 3), 7)
	assert_false(grid.can_place(Vector2i(4, 4), Vector2i(2, 2)), "overlap rejected")
	assert_false(grid.stamp_building(8, Vector2i(4, 4), Vector2i(2, 2)))
	assert_true(grid.can_place(Vector2i(5, 5), Vector2i(2, 2)))
	grid.remove_building(7, Vector2i(2, 2), Vector2i(3, 3))
	assert_eq(grid.building_at(3, 3), 0)
	assert_true(grid.can_place(Vector2i(4, 4), Vector2i(2, 2)))
	# 256 buildable minus nothing occupied now
	assert_eq(grid.count_buildable(0, 0), 256)


func test_out_of_bounds_placement_rejected() -> void:
	var grid := TileGrid.new()
	for z in range(0, 112):
		for x in range(0, 112):
			grid.set_flag(x, z, TileGrid.FLAG_BUILDABLE)
	assert_false(grid.can_place(Vector2i(110, 110), Vector2i(3, 3)))


func _tutorial_block() -> LandBlock:
	# B_3_1 (D2) exactly as authored in doc 09 §3.1.
	return LandBlock.from_dict({
		"id": "B_3_1", "grid": [3, 1], "label": "D2",
		"terrain_class": "flat", "dev_terrain": "flat",
		"elevation_class": 2, "flood_risk": 0.18,
		"env_risk": {"flood": 0.18, "wildfire": 0.20, "subsidence": 0.10,
				"pollution": 0.06, "wind": 0.22, "hazmat": 0.03},
		"road_access": "ARTERIAL", "arterial_connections": 2,
		"water_tiles": 0, "blocked_tiles": 0, "waterfront_edges": 0,
		"amenity_score": 0.45, "vegetation_density": 0.35, "slope_index": 0.05,
		"min_city_level": 0,
		"ownership_state": "PURCHASABLE", "development_state": "UNDEVELOPED",
		"district_id": null, "tags": ["tutorial_land_block"],
	})


func test_derived_attributes_worked_values() -> void:
	var b := _tutorial_block()
	# Doc 09 §2.4: B_3_1 risk 0.143
	assert_almost_eq(b.env_risk_index(), 0.1435, 0.0005)
	assert_eq(b.usable_tiles(), 256)
	assert_eq(b.road_tiles_est(), 87, "0.34 × 256 rounds to the authored template count")
	assert_eq(b.buildable_tiles_est(), 169, "clean block = 169")
	assert_eq(b.elevation_m(), 12)
	assert_eq(b.elevation_band(), &"MID")
	assert_almost_eq(b.block_road_access_score(), 1.0, 1e-9)
	# Doc 09 §2.2 drain table: B_3_1 = 25 × 0.856 × 1.25 = 26.75 ≈ 26.8
	assert_almost_eq(b.drain_rate_mm_h(), 26.75, 0.01)


func test_drain_rate_table() -> void:
	# The three other worked rows of doc 09 §2.2.
	var river := LandBlock.new()
	river.flood_risk = 0.80
	river.elevation_class = 0
	assert_almost_eq(river.drain_rate_mm_h(), 9.0, 0.01, "B_0_4 river bank")
	var flats := LandBlock.new()
	flats.flood_risk = 0.51
	flats.elevation_class = 1
	assert_almost_eq(flats.drain_rate_mm_h(), 16.65, 0.01, "B_1_3 the Flats")
	var ridge := LandBlock.new()
	ridge.flood_risk = 0.04
	ridge.elevation_class = 4
	assert_almost_eq(ridge.drain_rate_mm_h(), 36.3, 0.01, "B_6_2 ridge")
	assert_eq(river.elevation_band(), &"LOW")
	assert_eq(flats.elevation_band(), &"LOW")
	assert_eq(ridge.elevation_band(), &"HIGH")


func test_land_value_requires_ready() -> void:
	var b := _tutorial_block()
	assert_almost_eq(b.land_value_index(0.9), 0.0, 1e-9, "0 while undeveloped")
	b.development_state = &"READY"
	# 0.25 + 0.30×0.45 + 0.25×(1−0.1435) + 0.20×0.9 = 0.7791
	assert_almost_eq(b.land_value_index(0.9), 0.7791, 0.001)


func _make_world() -> WorldMap:
	var world := WorldMap.new()
	for bz in 7:
		for bx in 7:
			var owned: bool = bx >= 2 and bx <= 4 and bz >= 2 and bz <= 4
			var b := LandBlock.from_dict({
				"id": WorldMap.block_id_for(bx, bz), "grid": [bx, bz],
				"ownership_state": "OWNED" if owned else "LOCKED",
				"development_state": "READY" if owned else "UNDEVELOPED",
				"min_city_level": 0,
			})
			world.add_block(b)
	return world


func test_world_structure_and_d() -> void:
	var world := _make_world()
	assert_eq(world.block_count(), 49)
	assert_eq(world.owned_count(), 9, "3×3 core owned")
	assert_eq(world.d_from_center("B_3_3"), 0)
	assert_eq(world.d_from_center("B_3_1"), 2, "ring 1 ⇒ d = 2")
	assert_eq(world.d_from_center("B_0_6"), 3, "ring 2 ⇒ d = 3")
	assert_eq(world.d_from_center("B_0_0"), 3)


func test_adjacency_purchase_rule() -> void:
	var world := _make_world()
	# Edge-adjacent to the core: allowed.
	assert_true(bool(world.purchase_allowed("B_3_1", 0)["ok"]))
	# Diagonal corner of the core (B_1_1 touches B_2_2 only diagonally): rejected.
	assert_eq(world.purchase_allowed("B_1_1", 0)["reason_code"], &"E_NOT_ADJACENT")
	# Ring 2: not adjacent to anything owned.
	assert_eq(world.purchase_allowed("B_0_0", 0)["reason_code"], &"E_NOT_ADJACENT")
	# City-level gate fires before adjacency is even consulted.
	world.block("B_3_1").min_city_level = 2
	assert_eq(world.purchase_allowed("B_3_1", 0)["reason_code"], &"E_CITY_LEVEL")
	assert_true(bool(world.purchase_allowed("B_3_1", 2)["ok"]))
	# Already owned.
	assert_eq(world.purchase_allowed("B_3_3", 0)["reason_code"], &"E_ALREADY_OWNED")


func test_refresh_purchasable_states() -> void:
	var world := _make_world()
	world.refresh_purchasable(0)
	# 12 orthogonal ring-1 blocks purchasable; 4 diagonals + ring 2 locked (doc 09 §2.5).
	var purchasable := 0
	var locked := 0
	for id in world.block_ids_sorted():
		var b: LandBlock = world.block(id)
		if b.ownership_state == &"PURCHASABLE":
			purchasable += 1
		elif b.ownership_state == &"LOCKED":
			locked += 1
	assert_eq(purchasable, 12)
	assert_eq(locked, 28)
	# Buying a ring-1 edge block opens its neighbours.
	world.block("B_1_2").ownership_state = &"OWNED"
	world.refresh_purchasable(0)
	assert_eq(world.block("B_1_1").ownership_state, &"PURCHASABLE",
			"diagonal corner opens once an edge-neighbour is owned")
	assert_eq(world.block("B_0_2").ownership_state, &"PURCHASABLE", "ring 2 opens westward")


func test_block_save_roundtrip() -> void:
	var b := _tutorial_block()
	b.ownership_state = &"OWNED"
	b.development_state = &"GRADING"
	b.phase_crew_minutes_remaining = 743
	b.purchase_price = 12600
	b.purchased_minute = 1980
	b.survey_revealed = true
	var restored := _tutorial_block()
	restored.apply_save(b.serialize())
	assert_eq(restored.ownership_state, &"OWNED")
	assert_eq(restored.development_state, &"GRADING")
	assert_eq(restored.phase_crew_minutes_remaining, 743)
	assert_eq(restored.purchase_price, 12600)
	assert_true(restored.survey_revealed)


func test_grid_elevation_from_blocks() -> void:
	var world := _make_world()
	world.block("B_3_1").elevation_class = 2
	world.add_block(world.block("B_3_1"))  # re-add refreshes grid elevation
	assert_eq(world.grid.elev_m(56, 24), 12, "tile in B_3_1 reports its block's elevation")
