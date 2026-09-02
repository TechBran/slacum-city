extends SimTest
## **PA-76's missing gate.** Tile→world conversion is written eight times in this
## tree under six constant names, and the footprint→centre formula four times. At
## the Wave-17 fork *no test asserted any of them agreed* — the audit found the
## drift by reading, which is exactly the failure mode a gate exists to end.
##
## Two halves:
##
##  1. **Agreement.** Every mirrored spelling still equals `TileGrid.METRES_PER_TILE`,
##     and `TileGrid.METRES_PER_TILE` still equals the STORE (`data/world.json`
##     `world.tile_meters`). A lane that retunes the store and forgets a mirror
##     fails here instead of shipping a renderer half a city out of register.
##  2. **The formulas.** `TileGrid.centre_of*` reproduces, exactly, the hand-written
##     expressions the shell and the renderer already use — which is what makes
##     adopting them hash-neutral rather than a silent geometry change.
##
## The migration of the eight spellings is one row per owning lane (doc 98 §50);
## this file is what makes each of those a one-line change that cannot go wrong
## quietly.

const WORLD_JSON := "res://data/world.json"


# ------------------------------------------------------------------ the store

func test_the_constant_equals_the_store() -> void:
	# `data/world.json` is the authority the constant mirrors. Constitution §6
	# and doc 09 §2.1 both name it; four files quote it in a comment and none
	# checked it.
	var world: Dictionary = StarterCityLoader.read_json(WORLD_JSON)
	var header: Dictionary = world.get("world", {})
	assert_almost_eq(TileGrid.METRES_PER_TILE, float(header.get("tile_meters", -1.0)),
			0.0001, "TileGrid.METRES_PER_TILE vs world.json world.tile_meters")
	assert_eq(TileGrid.TILES_PER_BLOCK, int(header.get("block_tiles", -1)),
			"TileGrid.TILES_PER_BLOCK vs world.json world.block_tiles")
	assert_almost_eq(TileGrid.METRES_PER_BLOCK, 128.0, 0.0001,
			"a land block is 16 tiles = 128 m")


# ------------------------------------------------------- the eight duplicates

func test_every_mirrored_spelling_agrees() -> void:
	# One row per file that declares its own copy of the number. Named
	# individually rather than looped, so a failure says WHICH file drifted.
	var mirrors := {
		"IncidentWorld.METRES_PER_TILE": IncidentWorld.METRES_PER_TILE,
		"Vehicle.METRES_PER_TILE": Vehicle.METRES_PER_TILE,
		"WaterEdge.METRES_PER_TILE": WaterEdge.METRES_PER_TILE,
		"TravelTimeProvider.METRES_PER_TILE": TravelTimeProvider.METRES_PER_TILE,
		"WeatherSystem.TILE_METERS": WeatherSystem.TILE_METERS,
		"RoadSurfaceView.TILE_M": RoadSurfaceView.TILE_M,
		"StreetlightPlacer.TILE_M": StreetlightPlacer.TILE_M,
		"StreetLifeView.DEF_TILE_M": StreetLifeView.DEF_TILE_M,
		"ConstructionVehicleView.DEF_TILE_M": ConstructionVehicleView.DEF_TILE_M,
		"BuildController.TILE_M_DEFAULT": BuildController.TILE_M_DEFAULT,
		"AudioEvents._DEFAULT_TILE_M": AudioEvents._DEFAULT_TILE_M,
	}
	for name: String in mirrors:
		assert_almost_eq(float(mirrors[name]), TileGrid.METRES_PER_TILE, 0.0001,
				"%s drifted from TileGrid.METRES_PER_TILE" % name)


# ----------------------------------------------------------------- the shapes

func test_a_tile_centre_is_half_a_tile_in_from_its_corner() -> void:
	var corner := TileGrid.corner_of(Vector2i(10, 12))
	var centre := TileGrid.centre_of(Vector2i(10, 12))
	assert_almost_eq(corner.x, 80.0, 0.0001)
	assert_almost_eq(corner.z, 96.0, 0.0001)
	assert_almost_eq(centre.x, 84.0, 0.0001)
	assert_almost_eq(centre.z, 100.0, 0.0001)
	assert_almost_eq(centre.y, 0.0, 0.0001, "every locator answer is on GRADE")


func test_a_one_by_one_footprint_centre_is_the_tile_centre() -> void:
	# The property that makes `centre_of_footprint` safe to use in the places
	# that only ever wanted a tile centre.
	for tile: Vector2i in [Vector2i(0, 0), Vector2i(7, 3), Vector2i(111, 111)]:
		var a := TileGrid.centre_of_footprint(tile, Vector2i.ONE)
		var b := TileGrid.centre_of(tile)
		assert_almost_eq(a.x, b.x, 0.0001)
		assert_almost_eq(a.z, b.z, 0.0001)


func test_the_footprint_centre_reproduces_the_hand_written_formula() -> void:
	# `main.gd._building_view` / `_add_construction_site` / `PowerInfraFeed.
	# building_view` / `showcase.gd` all wrote this by hand as
	# `origin * 8.0 + size * 4.0`. Adopting the helper must not move a single
	# building — that is what "hash-neutral" means for PA-76.
	for size: Vector2i in [Vector2i(1, 1), Vector2i(2, 3), Vector2i(4, 4)]:
		var origin := Vector2i(9, 17)
		var by_hand := Vector3(origin.x * 8.0 + size.x * 4.0, 0.0,
				origin.y * 8.0 + size.y * 4.0)
		var helper := TileGrid.centre_of_footprint(origin, size)
		assert_almost_eq(helper.x, by_hand.x, 0.0001)
		assert_almost_eq(helper.z, by_hand.z, 0.0001)


func test_a_zero_size_footprint_is_treated_as_one_tile() -> void:
	# A record with a missing `footprint` defaults to `Vector2i.ONE` at the call
	# sites, but a malformed save could hand in a zero. Clamping here keeps a
	# focus on the tile rather than on its corner.
	var centre := TileGrid.centre_of_footprint(Vector2i(3, 4), Vector2i.ZERO)
	assert_almost_eq(centre.x, TileGrid.centre_of(Vector2i(3, 4)).x, 0.0001)


func test_the_block_centre_reproduces_the_hand_written_formula() -> void:
	# `main.gd._alert_world_pos` and `_on_fix_requested` both wrote this as
	# `(grid * 16 + 8) * tile_m`, with the 16 as a bare literal beside a
	# `TILES_PER_BLOCK` that already existed (PA-76 evidence).
	for g: Vector2i in [Vector2i(0, 0), Vector2i(2, 2), Vector2i(6, 6)]:
		var by_hand := Vector3((g.x * 16 + 8) * 8.0, 0.0, (g.y * 16 + 8) * 8.0)
		var helper := TileGrid.centre_of_block(g)
		assert_almost_eq(helper.x, by_hand.x, 0.0001)
		assert_almost_eq(helper.z, by_hand.z, 0.0001)


func test_tile_at_is_the_inverse_of_centre_of() -> void:
	for tile: Vector2i in [Vector2i(0, 0), Vector2i(55, 3), Vector2i(111, 90)]:
		assert_eq(TileGrid.tile_at(TileGrid.centre_of(tile)), tile)
		assert_eq(TileGrid.tile_at(TileGrid.corner_of(tile)), tile,
				"the corner belongs to its own tile")


func test_tile_at_floors_rather_than_truncating() -> void:
	# Truncation folds every point in (-8, 0) onto tile 0, which reads as "the
	# tap landed on the map" for a tap that landed west of it.
	assert_eq(TileGrid.tile_at(Vector3(-1.0, 0.0, -1.0)), Vector2i(-1, -1))
	assert_false(TileGrid.in_bounds(-1, -1), "and -1 is out of bounds")
