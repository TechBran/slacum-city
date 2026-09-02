extends SimTest
## `WorldLocator` — sim id → a point in metres, one test per kind (PA-38, PA-76).
##
## This is the half of `game/main.gd` that could not be tested at the Wave-17
## fork. `_alert_world_pos` and `_on_fix_requested` each carried their own copy
## of this reasoning inside a 2,229-line file with zero test references, and both
## copies were wrong: a transformer id looked up among buildings, a building
## anchored on its NW corner tile, `16` written three times as a bare literal,
## and a linear scan of `sim.buildings.keys()` for a key the caller was holding.


func _sim() -> CitySim:
	return CitySim.boot_from_files()


# ------------------------------------------------------------------ per kind

func test_a_tile_resolves_to_its_centre() -> void:
	var sim := _sim()
	var at: Variant = WorldLocator.locate(sim, WorldLocator.KIND_TILE, Vector2i(10, 12))
	assert_true(at is Vector3, "a tile always resolves")
	assert_almost_eq((at as Vector3).x, 84.0, 0.001, "10 tiles + half a tile")
	assert_almost_eq((at as Vector3).z, 100.0, 0.001)
	assert_almost_eq((at as Vector3).y, 0.0, 0.001, "on grade")


func test_a_tile_also_resolves_from_its_text_form() -> void:
	# Doc 07 keys a flood cell as text; the alerts centre republishes it.
	var sim := _sim()
	var by_text: Variant = WorldLocator.locate(sim, WorldLocator.KIND_TILE, "10,12")
	var by_vector: Variant = WorldLocator.locate(sim, WorldLocator.KIND_TILE, Vector2i(10, 12))
	assert_eq(by_text, by_vector)


func test_a_building_resolves_to_its_FOOTPRINT_centre_not_its_origin_tile() -> void:
	# **The wrong camera anchor.** `APT-001` is 2×2 at (40, 33): its origin tile
	# is (320, 264) m and its lot centre is (328, 272) m. The shell answered the
	# former on both of its paths, so `Fix this →` on a big building put the
	# camera on the corner of the lot next door.
	var sim := _sim()
	var at: Variant = WorldLocator.locate(sim, WorldLocator.KIND_BUILDING, "APT-001")
	assert_true(at is Vector3)
	assert_almost_eq((at as Vector3).x, 328.0, 0.001, "40 * 8 + 2 * 8 / 2")
	assert_almost_eq((at as Vector3).z, 272.0, 0.001, "33 * 8 + 2 * 8 / 2")
	assert_ne((at as Vector3).x, 320.0, "not the origin TILE, which is what the shell answered")


func test_a_one_by_one_building_lands_on_its_tile_centre() -> void:
	var sim := _sim()
	var at: Variant = WorldLocator.locate(sim, WorldLocator.KIND_BUILDING, "H-001")
	assert_almost_eq((at as Vector3).x, 36.0 * 8.0 + 4.0, 0.001)
	assert_almost_eq((at as Vector3).z, 33.0 * 8.0 + 4.0, 0.001)


func test_a_building_resolves_from_its_INTEGER_render_id() -> void:
	# `AlertsModel` publishes the integer grid id on some rows; the shell's own
	# `_alert_world_pos` handled both forms with a linear scan and the fix router
	# handled neither.
	var sim := _sim()
	var by_int: Variant = WorldLocator.locate(sim, WorldLocator.KIND_BUILDING, "4")
	var by_sim_id: Variant = WorldLocator.locate(sim, WorldLocator.KIND_BUILDING, "APT-001")
	assert_eq(by_int, by_sim_id, "APT-001 is grid id 4")


func test_a_block_resolves_to_the_centre_of_its_sixteen_tiles() -> void:
	var sim := _sim()
	var at: Variant = WorldLocator.locate(sim, WorldLocator.KIND_BLOCK, "B_2_2")
	assert_true(at is Vector3)
	assert_almost_eq((at as Vector3).x, 2.0 * 128.0 + 64.0, 0.001)
	assert_almost_eq((at as Vector3).z, 2.0 * 128.0 + 64.0, 0.001)
	# Doc 12 §4.5 spells the same kind `block_id`; both must answer.
	assert_eq(WorldLocator.locate(sim, WorldLocator.KIND_BLOCK_ID, "B_2_2"), at)


func test_a_flood_cell_resolves_at_block_scale_when_it_carries_the_B_prefix() -> void:
	# `"B<bx>,<bz>"` and `"<tx>,<tz>"` differ by ONE character and by a factor of
	# sixteen. Getting them the wrong way round puts the camera in the sea.
	var sim := _sim()
	var block_cell: Variant = WorldLocator.locate(sim, WorldLocator.KIND_CELL, "B2,2")
	var tile_cell: Variant = WorldLocator.locate(sim, WorldLocator.KIND_CELL, "2,2")
	assert_almost_eq((block_cell as Vector3).x, 320.0, 0.001)
	assert_almost_eq((tile_cell as Vector3).x, 20.0, 0.001)


func test_a_grid_component_resolves_to_its_tile() -> void:
	# **PA-05's mismatch, resolved.** `T-01` sits on tile (32, 32).
	var sim := _sim()
	var at: Variant = WorldLocator.locate(sim, WorldLocator.KIND_COMPONENT, "T-01")
	assert_true(at is Vector3, "a transformer is somewhere")
	assert_almost_eq((at as Vector3).x, 32.0 * 8.0 + 4.0, 0.001)
	assert_almost_eq((at as Vector3).z, 32.0 * 8.0 + 4.0, 0.001)


func test_a_transformer_id_asked_for_as_a_BUILDING_still_resolves() -> void:
	# This is the exact PA-05 failure: `build_controller.gd` fills
	# `fix_target_id` from `sim.grid.attachment_of(sim_id)` — a TRANSFORMER id —
	# and `requirement_formatter.gd` maps the code to a BUILDING kind. The shell
	# then did `sim.buildings.get(id)` and returned on null. The locator falls
	# through the namespaces instead.
	var sim := _sim()
	var attached := String(sim.grid.attachment_of("APT-001"))
	assert_eq(attached, "T-02", "the fixture the bug was reported against")
	var at: Variant = WorldLocator.locate(sim, WorldLocator.KIND_BUILDING, attached)
	assert_true(at is Vector3, "a transformer id in the building slot must not vanish")
	assert_eq(at, WorldLocator.locate(sim, WorldLocator.KIND_COMPONENT, attached),
			"and it must answer where the transformer actually is")


func test_a_district_resolves_to_the_mean_of_its_blocks() -> void:
	var sim := _sim()
	var at: Variant = WorldLocator.locate(sim, WorldLocator.KIND_DISTRICT, "D_DOWNTOWN")
	assert_true(at is Vector3)
	# D_DOWNTOWN is B_3_3 + B_4_3: centres (448, 448) and (576, 448).
	assert_almost_eq((at as Vector3).x, 512.0, 0.001)
	assert_almost_eq((at as Vector3).z, 448.0, 0.001)


func test_a_road_segment_resolves_to_the_nearest_avenue() -> void:
	# `E_AVENUE`'s target (C-62). Given the building that is short of an avenue,
	# answer the avenue — and prove the answer IS one.
	var sim := _sim()
	var at: Variant = WorldLocator.locate(sim, WorldLocator.KIND_ROAD_SEGMENT, "APT-001")
	assert_true(at is Vector3, "the starter city has 540 avenue tiles")
	var tile := TileGrid.tile_at(at as Vector3)
	assert_eq(sim.world.grid.road_class_at(tile.x, tile.y), TileGrid.ROAD_AVENUE,
			"the point the camera is sent to is on an avenue")


func test_the_nearest_avenue_is_the_nearest_one() -> void:
	var sim := _sim()
	var b: Building = sim.buildings["APT-001"]
	var tile := WorldLocator.nearest_road_tile(sim, b.origin, TileGrid.ROAD_AVENUE)
	var found := maxi(absi(tile.x - b.origin.x), absi(tile.y - b.origin.y))
	# Nothing strictly closer exists on any ring inside the one we answered.
	for z in range(b.origin.y - found + 1, b.origin.y + found):
		for x in range(b.origin.x - found + 1, b.origin.x + found):
			if TileGrid.in_bounds(x, z):
				assert_ne(sim.world.grid.road_class_at(x, z), TileGrid.ROAD_AVENUE,
						"a closer avenue existed at %d,%d" % [x, z])


# --------------------------------------------------------------- the refusals

func test_an_unknown_id_answers_null_rather_than_a_point() -> void:
	# `null` is a STATEMENT — "there is nowhere to jump" — and the router turns
	# it into a named refusal. What it must never be is `Vector3.ZERO`, which is
	# a real corner of a real map.
	var sim := _sim()
	assert_eq(WorldLocator.locate(sim, WorldLocator.KIND_BUILDING, "NOPE-999"), null)
	assert_eq(WorldLocator.locate(sim, WorldLocator.KIND_BLOCK, "B_9_9"), null)
	assert_eq(WorldLocator.locate(sim, WorldLocator.KIND_DISTRICT, "D_NOWHERE"), null)
	assert_eq(WorldLocator.locate(sim, WorldLocator.KIND_COMPONENT, "T-99"), null)
	assert_eq(WorldLocator.locate(sim, WorldLocator.KIND_TILE, "not a tile"), null)
	assert_eq(WorldLocator.locate(sim, &"invented_kind", "APT-001"), null)


func test_a_null_sim_answers_null() -> void:
	assert_eq(WorldLocator.locate(null, WorldLocator.KIND_BUILDING, "APT-001"), null)
	assert_eq(WorldLocator.locate_any(null, "APT-001"), null)


func test_locate_any_walks_the_namespaces_in_order() -> void:
	var sim := _sim()
	assert_eq(WorldLocator.locate_any(sim, "APT-001"),
			WorldLocator.locate(sim, WorldLocator.KIND_BUILDING, "APT-001"))
	assert_eq(WorldLocator.locate_any(sim, "T-01"),
			WorldLocator.locate(sim, WorldLocator.KIND_COMPONENT, "T-01"))
	assert_eq(WorldLocator.locate_any(sim, "B_2_2"),
			WorldLocator.locate(sim, WorldLocator.KIND_BLOCK, "B_2_2"))
	assert_eq(WorldLocator.locate_any(sim, "D_DOWNTOWN"),
			WorldLocator.locate(sim, WorldLocator.KIND_DISTRICT, "D_DOWNTOWN"))
	assert_eq(WorldLocator.locate_any(sim, ""), null)
	assert_eq(WorldLocator.locate_any(sim, "WAT-000"), null)


func test_every_locator_answer_is_on_grade() -> void:
	# The render layer applies per-block elevation to meshes; a locator that
	# guessed at it would put the camera under the two raised blocks.
	var sim := _sim()
	for pair: Array in [[WorldLocator.KIND_BUILDING, "APT-001"],
			[WorldLocator.KIND_BLOCK, "B_2_2"], [WorldLocator.KIND_TILE, Vector2i(3, 3)],
			[WorldLocator.KIND_COMPONENT, "T-01"], [WorldLocator.KIND_DISTRICT, "D_DOWNTOWN"],
			[WorldLocator.KIND_CELL, "B2,2"], [WorldLocator.KIND_ROAD_SEGMENT, "APT-001"]]:
		var at: Variant = WorldLocator.locate(sim, pair[0], pair[1])
		assert_almost_eq((at as Vector3).y, 0.0, 0.0001, "%s is on grade" % [pair[0]])
