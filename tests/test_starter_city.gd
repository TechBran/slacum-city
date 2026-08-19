extends SimTest
## Doc 09 P0-11: the data-integrity validators of doc 09 §7 (tests 1–9) run
## against the committed `data/starter_city.json` and `data/world.json`, through
## `StarterCityLoader` — the same path Milestone 1 loads the city with.
##
## Every expected number here is quoted from doc 09 (§2.8.2 sheet, §2.9.1 road
## template, §2.9.3 manifest, §2.9.4 totals, §2.9.5 power, §2.9.6 water,
## §2.9.7 tags, §3.1 schema, §8.1 world.json).

const CITY_PATH := "res://data/starter_city.json"
const WORLD_PATH := "res://data/world.json"

const CORE_OFFSET := 32
const CORE_TILES := 48

# Doc 04 component ratings quoted by doc 09 §2.9.5.
const TRANSFORMER_CAPACITY_KW := {1: 50.0, 2: 150.0, 3: 400.0}
const TRANSFORMER_MVA := {1: 0.05, 2: 0.15, 3: 0.40}
const TRANSFORMER_HEADROOM_FRAC := 0.70
const TRANSFORMER_L1_RADIUS := 3


func _city_data() -> Dictionary:
	var data := StarterCityLoader.read_json(CITY_PATH)
	assert_false(data.is_empty(), "data/starter_city.json parses")
	return data


func _loaded() -> StarterCityLoader:
	var loader := StarterCityLoader.new()
	var ok := loader.load_from(_city_data())
	assert_true(ok, "loader reported: " + ", ".join(loader.errors))
	return loader


func _is_road_local(loader: StarterCityLoader, x: int, z: int) -> bool:
	if x < 0 or x >= CORE_TILES or z < 0 or z >= CORE_TILES:
		return false
	return loader.world.grid.road_class_at(x + CORE_OFFSET, z + CORE_OFFSET) != TileGrid.ROAD_NONE


func _cheb(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


## JSON numbers parse as floats; compare integer coordinate arrays as ints.
func _ints(values: Variant) -> Array:
	var out: Array = []
	for v in (values as Array):
		out.append(int(v))
	return out


# --- 1. file loads, block census (doc 09 §7 test 1) ------------------------

func test_file_loads_and_block_census() -> void:
	var loader := _loaded()
	assert_eq(loader.schema_version, 2, "data-file schema_version (§3.1)")
	assert_eq(_ints(loader.world_header.get("size_blocks")), [7, 7])
	assert_eq(loader.world_header.get("tile_meters"), 8)
	assert_eq(loader.world_header.get("block_tiles"), 16)
	assert_eq(_ints(loader.world_header.get("city_center_tile")), [56, 56])
	assert_eq(_ints(loader.world_header.get("core_origin_block")), [2, 2])
	assert_eq(_ints(loader.world_header.get("core_size_blocks")), [3, 3])

	assert_eq(loader.world.block_count(), 49, "7×7 world (§2.1)")
	var owned := 0
	var purchasable := 0
	var locked := 0
	var ready := 0
	for id in loader.world.block_ids_sorted():
		var b: LandBlock = loader.world.block(id)
		match b.ownership_state:
			&"OWNED":
				owned += 1
			&"PURCHASABLE":
				purchasable += 1
			&"LOCKED":
				locked += 1
		if b.is_ready():
			ready += 1
		assert_true(b.min_city_level >= 0 and b.min_city_level <= 5,
				"%s min_city_level is on the §2.11 ladder" % id)
	assert_eq(owned, 9, "9 OWNED core blocks at t0")
	assert_eq(ready, 9, "the 9 OWNED blocks are all READY")
	assert_eq(purchasable, 12, "12 PURCHASABLE at t0 (§2.5)")
	assert_eq(locked, 28, "28 LOCKED at t0")

	# The 4 ring-1 diagonals are LOCKED on adjacency, not on city level (§2.5).
	for id in ["B_1_1", "B_5_1", "B_1_5", "B_5_5"]:
		var b: LandBlock = loader.world.block(id)
		assert_eq(b.ownership_state, &"LOCKED", "%s ring-1 diagonal is LOCKED" % id)
		assert_eq(b.min_city_level, 0, "%s is gated by adjacency alone" % id)
	# Every PURCHASABLE block is reachable at city_level 0 (§7 test 35).
	for id in loader.world.block_ids_sorted():
		var b: LandBlock = loader.world.block(id)
		if b.ownership_state == &"PURCHASABLE":
			assert_eq(b.min_city_level, 0, "%s purchasable at city_level 0" % id)


# --- 2. block attribute sheet (doc 09 §2.8.2 / §3.1) -----------------------

func test_block_attribute_sheet() -> void:
	var loader := _loaded()

	# The §3.1 example row, field for field.
	var b := loader.world.block("B_3_1")
	assert_eq(b.grid, Vector2i(3, 1))
	assert_eq(b.label, "D2")
	assert_eq(b.terrain_class, &"flat")
	assert_eq(b.dev_terrain, &"flat")
	assert_eq(b.elevation_class, 2)
	assert_almost_eq(b.flood_risk, 0.18, 1e-9)
	assert_almost_eq(float(b.env_risk["wildfire"]), 0.20, 1e-9)
	assert_almost_eq(float(b.env_risk["subsidence"]), 0.10, 1e-9)
	assert_almost_eq(float(b.env_risk["pollution"]), 0.06, 1e-9)
	assert_almost_eq(float(b.env_risk["wind"]), 0.22, 1e-9)
	assert_almost_eq(float(b.env_risk["hazmat"]), 0.03, 1e-9)
	assert_eq(b.road_access, &"ARTERIAL")
	assert_eq(b.arterial_connections, 2)
	assert_eq(b.water_tiles, 0)
	assert_eq(b.blocked_tiles, 0)
	assert_eq(b.waterfront_edges, 0)
	assert_almost_eq(b.amenity_score, 0.45, 1e-9)
	assert_almost_eq(b.vegetation_density, 0.35, 1e-9)
	assert_almost_eq(b.slope_index, 0.05, 1e-9)
	assert_eq(b.min_city_level, 0)
	assert_eq(b.ownership_state, &"PURCHASABLE")
	assert_eq(b.development_state, &"UNDEVELOPED")
	assert_true(b.tags.has("tutorial_land_block"), "B_3_1 carries the tutorial tag")
	assert_almost_eq(b.env_risk_index(), 0.1435, 0.0006, "§2.8.2 ERI 0.143")
	assert_eq(b.buildable_tiles_est(), 169, "clean block estimate")

	# Sheet spot checks across every terrain family.
	var marsh := loader.world.block("B_0_6")
	assert_eq(marsh.dev_terrain, &"marsh")
	assert_eq(marsh.water_tiles, 96)
	assert_eq(marsh.waterfront_edges, 3)
	assert_eq(marsh.min_city_level, 2)
	assert_eq(marsh.buildable_tiles_est(), 106, "§2.8.2 buildable for A7")
	assert_almost_eq(marsh.env_risk_index(), 0.4425, 0.0006, "§2.8.2 ERI 0.443")

	var river := loader.world.block("B_0_4")
	assert_eq(river.water_tiles, 80)
	assert_eq(river.buildable_tiles_est(), 116, "§2.8.2 buildable for A5")
	assert_almost_eq(river.env_risk_index(), 0.408, 0.0006)

	var hills_low := loader.world.block("B_5_3")
	assert_eq(hills_low.dev_terrain, &"hilly")
	assert_eq(hills_low.blocked_tiles, 16)
	assert_eq(hills_low.buildable_tiles_est(), 158, "§2.8.2 buildable for F4")
	assert_eq(hills_low.arterial_connections, 2, "core AVENUE + SR-14")

	var ridge := loader.world.block("B_6_2")
	assert_eq(ridge.dev_terrain, &"steep")
	assert_eq(ridge.blocked_tiles, 40)
	assert_eq(ridge.buildable_tiles_est(), 143, "§2.8.2 buildable for G3")
	assert_eq(ridge.elevation_class, 4)
	assert_eq(ridge.elevation_band(), &"HIGH")

	var industrial := loader.world.block("B_5_5")
	assert_eq(industrial.terrain_class, &"industrial_edge")
	assert_eq(industrial.dev_terrain, &"forest")
	assert_almost_eq(industrial.env_risk_index(), 0.3345, 0.0006, "§2.8.2 ERI 0.335")

	# §2.2's worked drain-rate rows.
	assert_almost_eq(loader.world.block("B_0_4").drain_rate_mm_h(), 9.0, 0.02, "A5 river bank")
	assert_almost_eq(loader.world.block("B_1_3").drain_rate_mm_h(), 16.65, 0.02, "B4 the Flats")
	assert_almost_eq(loader.world.block("B_3_1").drain_rate_mm_h(), 26.75, 0.02, "D2 farmland")
	assert_almost_eq(loader.world.block("B_6_2").drain_rate_mm_h(), 36.3, 0.02, "G3 ridge")

	# Mill Pond distorts B_2_3's template: estimate 159, direct count 154 (§2.2).
	var mill := loader.world.block("B_2_3")
	assert_eq(mill.water_tiles, 15)
	assert_eq(mill.buildable_tiles_est(), 159, "pre-development estimate")
	assert_eq(loader.count_block_buildable(2, 3), 154, "direct count from the tile grid")


# --- 3. road template (doc 09 §7 test 4) -----------------------------------

func test_road_template_counts() -> void:
	var loader := _loaded()
	assert_eq(loader.road_entries.size(), 18, "18 template entries (§3.1)")
	assert_eq(loader.count_core_road_tiles(), 783, "core road tiles (§2.9.1)")
	assert_eq(loader.count_core_road_tiles(TileGrid.ROAD_AVENUE), 540, "AVENUE tiles")
	assert_eq(loader.count_core_road_tiles(TileGrid.ROAD_STREET), 243, "STREET tiles")

	# 9 lines per axis ⇒ 81 grid intersections.
	var x_indices: Dictionary = {}
	var z_indices: Dictionary = {}
	for entry in loader.road_entries:
		if String(entry["axis"]) == "x":
			x_indices[int(entry["index"])] = true
		else:
			z_indices[int(entry["index"])] = true
		assert_eq(int(entry["from"]), 0)
		assert_eq(int(entry["to"]), 47)
	assert_eq(x_indices.size(), 9, "road columns")
	assert_eq(z_indices.size(), 9, "road rows")
	assert_eq(x_indices.size() * z_indices.size(), 81, "road-grid intersections")

	# 87 road tiles per core block; a clean block counts 169 buildable.
	for bz in range(2, 5):
		for bx in range(2, 5):
			var roads := 0
			for z in range(bz * 16, bz * 16 + 16):
				for x in range(bx * 16, bx * 16 + 16):
					if loader.world.grid.road_class_at(x, z) != TileGrid.ROAD_NONE:
						roads += 1
			assert_eq(roads, 87, "road tiles in B_%d_%d" % [bx, bz])
	assert_eq(loader.count_block_buildable(3, 3), 169, "clean block buildable count")
	assert_eq(loader.count_block_buildable(4, 4), 169, "clean block buildable count")
	assert_eq(loader.count_vacant_lots(), 1429, "vacant buildable lots (§2.9.4)")

	# Road tiles are never buildable; the culvert at (0,19) is road, not water.
	assert_false(loader.world.grid.has_flag(CORE_OFFSET, CORE_OFFSET,
			TileGrid.FLAG_BUILDABLE), "road tile is not buildable")
	assert_true(_is_road_local(loader, 0, 19), "Levee Rd (0,19) is a culvert")
	assert_false(loader.world.grid.has_flag(CORE_OFFSET + 0, CORE_OFFSET + 19,
			TileGrid.FLAG_WATER), "the culvert tile is not water")


# --- 4. building manifest (doc 09 §7 test 2) -------------------------------

func test_building_manifest_counts() -> void:
	var loader := _loaded()
	assert_eq(loader.buildings.size(), 34, "34 buildings (§2.9.3)")

	var counts: Dictionary = {}
	for record in loader.buildings:
		var type_name := String(record["type"])
		counts[type_name] = int(counts.get(type_name, 0)) + 1
		assert_eq(int(record["level"]), 1, "%s is Level 1" % record["id"])
	assert_eq(int(counts.get("house", 0)), 18, "18 houses")
	assert_eq(int(counts.get("store", 0)), 5, "5 stores")
	assert_eq(int(counts.get("apartment", 0)), 3, "3 apartments")
	assert_eq(int(counts.get("office", 0)), 1, "1 office")
	assert_eq(int(counts.get("construction_yard", 0)), 1)
	assert_eq(int(counts.get("fire_station", 0)), 1)
	assert_eq(int(counts.get("police_station", 0)), 1)
	assert_eq(int(counts.get("substation", 0)), 1)
	assert_eq(int(counts.get("power_facility", 0)), 1)
	assert_eq(int(counts.get("water_facility", 0)), 2, "WTR-1 + WTR-2 (C-35)")
	assert_eq(counts.size(), 10, "no archetype outside the §2.9.3 manifest")

	# The seven named civic/utility records, at their authored tiles.
	var expected := {
		"YARD-1": ["construction_yard", [1, 1], [2, 2], "B_2_2"],
		"FIRE-1": ["fire_station", [33, 1], [2, 2], "B_4_2"],
		"WTR-1": ["water_facility", [1, 20], [3, 3], "B_2_3"],
		"WTR-2": ["water_facility", [1, 24], [2, 2], "B_2_3"],
		"OFF-1": ["office", [24, 17], [2, 2], "B_3_3"],
		"SUB-A": ["substation", [33, 17], [2, 2], "B_4_3"],
		"POL-1": ["police_station", [1, 33], [2, 2], "B_2_4"],
		"PLANT-1": ["power_facility", [40, 40], [3, 3], "B_4_4"],
	}
	for id in expected:
		var record := loader.building(id)
		assert_false(record.is_empty(), "%s is present" % id)
		if record.is_empty():
			continue
		var row: Array = expected[id]
		assert_eq(String(record["type"]), String(row[0]), "%s type" % id)
		assert_eq(_ints(record["origin"]), row[1], "%s origin (core-local)" % id)
		assert_eq(_ints(record["size"]), row[2], "%s footprint" % id)
		assert_eq(String(record["block"]), String(row[3]), "%s block" % id)
	assert_eq(String(loader.building("WTR-1").get("variant", "")), "pump")
	assert_eq(String(loader.building("WTR-2").get("variant", "")), "tank",
			"the tank's 2×2 is doc 05's, not doc 02's (C-35)")

	# Total footprint area (§2.9.4): 18 + 12 + 5 + 4 + 16 + 9 + 9 + 4 = 77.
	var footprint := 0
	for record in loader.buildings:
		footprint += int(record["size"][0]) * int(record["size"][1])
	assert_eq(footprint, 77, "footprint tiles")
	assert_eq(48 * 48 - 783 - 15 - footprint, 1429, "vacant lots reconcile")


# --- 5. footprint legality (doc 09 §7 test 2) ------------------------------

func test_building_footprints_are_legal() -> void:
	var loader := _loaded()
	var seen: Dictionary = {}
	for record in loader.buildings:
		var origin: Vector2i = record["origin_local"]
		var size: Vector2i = record["footprint"]
		var road_adjacent := false
		for z in range(origin.y, origin.y + size.y):
			for x in range(origin.x, origin.x + size.x):
				var key := z * 100 + x
				assert_true(x >= 0 and x < CORE_TILES and z >= 0 and z < CORE_TILES,
						"%s tile (%d,%d) is inside the core" % [record["id"], x, z])
				assert_false(seen.has(key), "%s overlaps another footprint at (%d,%d)"
						% [record["id"], x, z])
				seen[key] = record["id"]
				var g := Vector2i(x + CORE_OFFSET, z + CORE_OFFSET)
				assert_false(loader.world.grid.has_flag(g.x, g.y, TileGrid.FLAG_ROAD),
						"%s sits on a road tile at (%d,%d)" % [record["id"], x, z])
				assert_false(loader.world.grid.has_flag(g.x, g.y, TileGrid.FLAG_WATER),
						"%s sits on water at (%d,%d)" % [record["id"], x, z])
				assert_eq(loader.world.grid.building_at(g.x, g.y), int(record["grid_id"]),
						"%s owns its tile (%d,%d)" % [record["id"], x, z])
				assert_eq(loader.world.block_of_tile(g.x, g.y).id, String(record["block"]),
						"%s tile (%d,%d) is inside its stated block" % [record["id"], x, z])
				if _is_road_local(loader, x + 1, z) or _is_road_local(loader, x - 1, z) \
						or _is_road_local(loader, x, z + 1) or _is_road_local(loader, x, z - 1):
					road_adjacent = true
		assert_true(road_adjacent,
				"%s is orthogonally adjacent to a road tile (§2.9.1)" % record["id"])
	assert_eq(seen.size(), 77, "77 occupied footprint tiles")


# --- 6. archetype adjacency (doc 09 §7 test 3) -----------------------------

func test_no_same_archetype_orthogonally_adjacent() -> void:
	var loader := _loaded()
	var type_at: Dictionary = {}
	var id_at: Dictionary = {}
	for record in loader.buildings:
		var origin: Vector2i = record["origin_local"]
		var size: Vector2i = record["footprint"]
		for z in range(origin.y, origin.y + size.y):
			for x in range(origin.x, origin.x + size.x):
				type_at[Vector2i(x, z)] = String(record["type"])
				id_at[Vector2i(x, z)] = String(record["id"])
	for tile in type_at:
		for offset in [Vector2i(1, 0), Vector2i(0, 1)]:
			var other: Vector2i = tile + offset
			if not type_at.has(other):
				continue
			if String(id_at[other]) == String(id_at[tile]):
				continue
			assert_ne(String(type_at[other]), String(type_at[tile]),
					"%s and %s are the same archetype and orthogonally adjacent"
					% [id_at[tile], id_at[other]])


# --- 7. transformer service radius (doc 09 §7 test 6) ----------------------

func test_every_building_within_transformer_radius() -> void:
	var loader := _loaded()
	var transformers := loader.power_nodes_of_kind("transformer")
	# **F-4 grid thinning, Wave 4** (doc 92 §14). Doc 09 §2.9.5 authored 23
	# transformers; five of them (T-05, T-08, T-16, T-21, T-22) were redundant
	# against the rule this very test states — every building origin within
	# Chebyshev 3 of SOME transformer — and doc 92 F-4 asked for the founding
	# grid to be thinned so `cmd_place_grid_component` stops being optional. The
	# surviving 18 are the minimum roster that still covers all 34 authored
	# buildings AND keeps the tutorial beats (tutorial_lot_a unserved,
	# tutorial_lot_b served, T-04 in place); the removed nodes' streetlights,
	# signals and building customers re-home to the nearest survivor, so the
	# night peak, the sink totals and the F_SOUTH lesson are all conserved.
	# Measured effect: served vacant ground 510 → 452 tiles, served 2×2 origins
	# 257 → 226. Doc 92 §14 carries the derivation and the geometric floor.
	assert_eq(transformers.size(), 18, "18 transformers (§2.9.5, thinned by doc 92 F-4)")
	for node in transformers:
		var tile := Vector2i(int(node["tile"][0]), int(node["tile"][1]))
		assert_true(_is_road_local(loader, tile.x, tile.y),
				"%s is sited on a road tile" % node["id"])
	for record in loader.buildings:
		var origin: Vector2i = record["origin_local"]
		var nearest := 999
		for node in transformers:
			var tile := Vector2i(int(node["tile"][0]), int(node["tile"][1]))
			nearest = mini(nearest, _cheb(origin, tile))
		assert_true(nearest <= TRANSFORMER_L1_RADIUS,
				"%s origin is %d tiles from the nearest transformer (max %d)"
				% [record["id"], nearest, TRANSFORMER_L1_RADIUS])


# --- 8. transformer fleet + sinks (doc 09 §7 test 6, §2.9.5) ---------------

func test_transformer_fleet_and_sizing() -> void:
	var loader := _loaded()
	var by_level: Dictionary = {1: 0, 2: 0, 3: 0}
	var rated_mva := 0.0
	var streetlights := 0
	var signals := 0
	var feeder_kw: Dictionary = {"F_NORTH": 0.0, "F_SOUTH": 0.0}
	for node in loader.power_nodes_of_kind("transformer"):
		var level := int(node["level"])
		assert_true(TRANSFORMER_CAPACITY_KW.has(level), "%s level in 1..3" % node["id"])
		by_level[level] = int(by_level[level]) + 1
		rated_mva += float(TRANSFORMER_MVA[level])
		streetlights += int(node["streetlights"])
		signals += int(node["signals"])
		var load_kw := float(node["night_load_kw"])
		var feeder := String(node["feeder"])
		assert_true(feeder_kw.has(feeder), "%s on a known feeder" % node["id"])
		feeder_kw[feeder] = float(feeder_kw[feeder]) + load_kw
		# The headroom rule, at every level (§2.9.5).
		assert_true(load_kw <= TRANSFORMER_HEADROOM_FRAC * float(TRANSFORMER_CAPACITY_KW[level]),
				"%s night load %.1f kW leaves < 30%% headroom at L%d" % [node["id"], load_kw, level])
		if level > 1:
			assert_true(load_kw > TRANSFORMER_HEADROOM_FRAC
					* float(TRANSFORMER_CAPACITY_KW[level - 1]),
					"%s is authored above the smallest level that satisfies the rule" % node["id"])
	# Wave-4 F-4 histogram. Dropping five nodes removes 4×L1 + 1×L2, and the two
	# survivors that inherit the biggest orphaned sink groups (T-19 takes T-21's
	# 46 streetlights, T-20 takes T-22's 74) cross the §2.9.5 headroom rule and
	# are re-authored L1 → L2: 13/9/1 → **7/10/1**.
	# `rated_mva = 7×0.05 + 10×0.15 + 1×0.40 = 0.35 + 1.50 + 0.40 = 2.25`.
	assert_eq(int(by_level[1]), 7, "7 × L1")
	assert_eq(int(by_level[2]), 10, "10 × L2")
	assert_eq(int(by_level[3]), 1, "1 × L3 (WTR-1's water works)")
	assert_almost_eq(rated_mva, 2.25, 1e-9, "fleet rated_mva")

	# Distributed sinks: one streetlight per road tile, one signal per
	# intersection. CONSERVED by the thinning — doc 04 §2.3 attaches a sink to
	# its nearest transformer with no radius limit, so removing a node moves its
	# sinks, it does not delete them. This pair is the invariant that proves it.
	assert_eq(streetlights, 783, "streetlight sinks == road tiles (§2.9.4)")
	assert_eq(signals, 81, "signal sinks == intersections")

	# Feeder rollups (§2.9.5). The city's night peak is conserved to the same
	# 0.1 kW of rounding drift the doc's own table carried (783.3 → 783.4); what
	# moves is the SPLIT, because a sink re-homes to its nearest node and four of
	# the five removed nodes sat on F_SOUTH: 361.8/421.6 → **365.8/417.6**.
	assert_almost_eq(float(feeder_kw["F_NORTH"]), 365.8, 0.15, "F_NORTH night load")
	assert_almost_eq(float(feeder_kw["F_SOUTH"]), 417.6, 0.15, "F_SOUTH night load")
	var total: float = float(feeder_kw["F_NORTH"]) + float(feeder_kw["F_SOUTH"])
	assert_almost_eq(total, 783.4, 0.25, "night peak building+sink load")
	assert_almost_eq(float(feeder_kw["F_SOUTH"]) / total, 0.533, 0.002,
			"F_SOUTH still carries 53.3 % of the city's night load — the designed "
			+ "lesson survives the thinning (was 53.8 %)")

	# The tutorial transformer and the radial topology.
	var t04 := loader.power_node("T-04")
	assert_eq(int(t04["level"]), 2)
	assert_eq(_ints(t04["tile"]), [35, 0])
	assert_true(Array(t04["tags"]).has("tutorial_transformer"))
	assert_eq(Array(loader.power.get("tie_switches", [])).size(), 0,
			"no tie switch at t0 — F_SOUTH is radial with no alternate supply")


# --- 9. power lines (doc 09 §7 test 5) -------------------------------------

func test_power_line_geometry_and_inventory() -> void:
	var loader := _loaded()
	var feeder_tiles := 0
	var transmission_tiles := 0
	for line in loader.power.get("lines", []):
		var paths: Array = [line["path"]]
		for lateral in line.get("laterals", []):
			paths.append(lateral)
		var length := 0
		for path in paths:
			# Axis-aligned, segment by segment.
			for i in range(1, path.size()):
				var a := Vector2i(int(path[i - 1][0]), int(path[i - 1][1]))
				var b := Vector2i(int(path[i][0]), int(path[i][1]))
				assert_true(a.x == b.x or a.y == b.y,
						"%s segment %s→%s is not axis-aligned" % [line["id"], a, b])
			# Entirely inside the road right-of-way.
			for tile in StarterCityLoader.polyline_tiles(path):
				assert_true(_is_road_local(loader, tile.x, tile.y),
						"%s leaves the road right-of-way at %s" % [line["id"], tile])
			length += StarterCityLoader.polyline_length(path)
		assert_eq(length, int(line["length_tiles"]), "%s length_tiles" % line["id"])
		if String(line["kind"]) == "feeder":
			feeder_tiles += length
		else:
			transmission_tiles += length
	assert_eq(transmission_tiles, 30, "transmission tiles (§2.9.5)")
	assert_eq(feeder_tiles, 147, "feeder tiles")
	assert_eq(transmission_tiles + feeder_tiles, 177, "total line tiles")
	assert_almost_eq((transmission_tiles + feeder_tiles) * 8.0 / 1000.0, 1.42, 0.01, "line_km")

	# Plant → substation, and both feeders leave SUB-A's HV terminal.
	var plant := loader.power_node("PLANT-1")
	var sub := loader.power_node("SUB-A")
	assert_eq(_ints(plant["terminal"]), [39, 41])
	assert_eq(_ints(sub["terminal"]), [32, 18])
	assert_eq(int(sub.get("feeder_slots", 0)), 2, "substation L1 has 2 feeder slots")
	assert_true(Array(sub["tags"]).has("tutorial_substation"))
	for line in loader.power.get("lines", []):
		var path: Array = line["path"]
		var first := Vector2i(int(path[0][0]), int(path[0][1]))
		if String(line["kind"]) == "feeder":
			assert_eq(first, Vector2i(32, 18), "%s starts at SUB-A" % line["id"])
		else:
			assert_eq(first, Vector2i(39, 41), "%s starts at PLANT-1" % line["id"])
			var last := Vector2i(int(path[-1][0]), int(path[-1][1]))
			assert_eq(last, Vector2i(32, 18), "%s ends at SUB-A" % line["id"])


# --- 10. water topology (doc 09 §7 tests 7, 9; §2.9.6) ---------------------

func test_water_topology() -> void:
	var loader := _loaded()

	# WTR-1 is one building hosting three co-located nodes at terminal (0,20).
	var site_kw := 0.0
	for id in ["WTR-1-SRC", "WTR-1-TRT", "WTR-1-PMP"]:
		var node := loader.water_node(id)
		assert_false(node.is_empty(), "%s exists" % id)
		assert_eq(_ints(node["terminal"]), [0, 20], "%s shares the WTR-1 terminal" % id)
		assert_eq(String(node["building"]), "WTR-1")
		site_kw += float(node["base_kw"])
	assert_almost_eq(site_kw, 132.0, 1e-9, "WTR-1 site load = 32 + 40 + 60 kW (C-35)")

	var tank := loader.water_node("WTR-2")
	assert_eq(String(tank["variant"]), "tank")
	assert_eq(_ints(tank["terminal"]), [0, 24])
	assert_almost_eq(float(tank["base_kw"]), 5.0, 1e-9, "a gravity tank draws 5 kW, not 60")
	assert_almost_eq(float(tank["capacity_m3"]), 120.0, 1e-9)
	assert_almost_eq(float(tank["head_m"]), 30.0, 1e-9)
	var tank_building := loader.building("WTR-2")
	assert_eq(_ints(tank_building["origin"]), [1, 24], "the tank building sits at (1,24)")
	assert_eq(_ints(tank_building["size"]), [2, 2], "doc 05's 2×2 tank footprint")
	# Tank autonomy (§2.9.6): 120 m³ ÷ draw.
	assert_almost_eq(120.0 / 5.56, 21.6, 0.05, "autonomy on the daily mean")
	assert_almost_eq(120.0 / 7.10, 16.9, 0.05, "autonomy at the morning peak")

	# P-2 is the standby pump the tutorial starts (§2.9.7).
	var pump := loader.water_node("WTR-1-PMP")
	var states: Dictionary = {}
	for p in pump["pumps"]:
		states[String(p["id"])] = String(p["state"])
	assert_eq(String(states.get("P-1", "")), "ok")
	assert_eq(String(states.get("P-2", "")), "offline_manual", "standby at t0")

	# The water works hangs off F_SOUTH with no backup generator — the cascade.
	var dependency: Dictionary = loader.water.get("power_dependency", {})
	assert_eq(String((dependency.get("WTR-1", {}) as Dictionary).get("feeder", "")), "F_SOUTH")
	assert_eq(String((dependency.get("WTR-1", {}) as Dictionary).get("transformer", "")), "T-15")
	assert_almost_eq(float((dependency.get("WTR-1", {}) as Dictionary)
			.get("backup_coverage_frac", -1.0)), 0.0, 1e-9, "no generator at L1 (doc 05 §2.6)")

	# Mains: authored lengths, axis-aligned, in the road right-of-way.
	var expected_mains := {"M_RISER": 4, "M_NORTH": 51, "M_SOUTH": 55, "M_TIE": 16}
	var main_tiles: Dictionary = {}
	for main in loader.water.get("mains", []):
		var id := String(main["id"])
		var length := StarterCityLoader.polyline_length(main["path"])
		assert_eq(length, int(expected_mains.get(id, -1)), "%s length (§2.9.6)" % id)
		for tile in StarterCityLoader.polyline_tiles(main["path"]):
			assert_true(_is_road_local(loader, tile.x, tile.y),
					"%s leaves the road right-of-way at %s" % [id, tile])
			main_tiles[tile] = true
	assert_eq(main_tiles.size() > 0, true)
	for lateral in loader.water.get("laterals", []):
		for tile in StarterCityLoader.polyline_tiles(lateral["path"]):
			assert_true(_is_road_local(loader, tile.x, tile.y),
					"water lateral leaves the road right-of-way at %s" % tile)
			main_tiles[tile] = true

	# Nine hydrants, all on road tiles (§2.9.6).
	var hydrants: Array = loader.water.get("hydrants", [])
	assert_eq(hydrants.size(), 9, "9 hydrants")
	var hydrant_tiles: Array = []
	for h in hydrants:
		var tile := Vector2i(int(h[0]), int(h[1]))
		hydrant_tiles.append(tile)
		assert_true(_is_road_local(loader, tile.x, tile.y), "hydrant %s is on a road tile" % tile)

	# Every core tile is inside one pressure zone: within 12 tiles of a live main
	# and of a hydrant (doc 05's max_service_distance_tiles).
	var main_list: Array = main_tiles.keys()
	var worst_main := 0
	var worst_hydrant := 0
	for z in CORE_TILES:
		for x in CORE_TILES:
			var tile := Vector2i(x, z)
			var best_main := 999
			for m in main_list:
				best_main = mini(best_main, _cheb(tile, m))
			var best_hydrant := 999
			for h in hydrant_tiles:
				best_hydrant = mini(best_hydrant, _cheb(tile, h))
			worst_main = maxi(worst_main, best_main)
			worst_hydrant = maxi(worst_hydrant, best_hydrant)
	assert_true(worst_main <= 12, "worst tile is %d tiles from a main (max 12)" % worst_main)
	assert_true(worst_hydrant <= 12,
			"worst tile is %d tiles from a hydrant (max 12)" % worst_hydrant)
	assert_eq(Array(loader.water.get("pressure_zones", [])).size(), 1, "one pressure zone Z1")

	# Mill Creek + Mill Pond: 15 water tiles, all flagged on the grid.
	assert_eq(loader.water_tiles.size(), 15, "15 surface-water tiles (§2.9.2)")
	assert_eq(loader.count_core_flag(TileGrid.FLAG_WATER), 15, "water flags stamped")
	for pair in loader.water_tiles:
		var g := StarterCityLoader.core_to_global(int(pair[0]), int(pair[1]))
		assert_true(loader.world.grid.has_flag(g.x, g.y, TileGrid.FLAG_WATER))
		assert_false(loader.world.grid.has_flag(g.x, g.y, TileGrid.FLAG_BUILDABLE),
				"water is not buildable")


# --- 11. districts (doc 09 §7 test 8) --------------------------------------

func test_districts() -> void:
	var loader := _loaded()
	assert_eq(loader.districts.size(), 4, "4 starter districts (§2.9.4)")
	var expected := {
		"D_NORTHGATE": ["B_2_2", "B_3_2", "B_4_2"],
		"D_DOWNTOWN": ["B_3_3", "B_4_3"],
		"D_MILLPOND": ["B_2_3", "B_2_4"],
		"D_FOUNDRY": ["B_3_4", "B_4_4"],
	}
	var claimed: Dictionary = {}
	for d in loader.districts:
		var id := String(d["id"])
		assert_true(expected.has(id), "district %s is in the §2.9.4 table" % id)
		var members: Array = d["blocks"]
		assert_eq(members, expected.get(id, []), "%s membership" % id)
		assert_true(members.size() >= 1 and members.size() <= 4, "%s holds 1–4 blocks" % id)
		# 4-connected membership.
		var coords: Array = []
		for bid in members:
			var block: LandBlock = loader.world.block(String(bid))
			assert_false(block == null, "%s references a live block" % id)
			assert_eq(block.district_id, id, "%s carries its district_id" % bid)
			assert_true(block.is_owned(), "%s is OWNED" % bid)
			assert_false(claimed.has(String(bid)), "%s is claimed by two districts" % bid)
			claimed[String(bid)] = id
			coords.append(block.grid)
		var reached: Array = [coords[0]]
		var frontier: Array = [coords[0]]
		while not frontier.is_empty():
			var current: Vector2i = frontier.pop_back()
			for offset in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
				var n: Vector2i = current + offset
				if coords.has(n) and not reached.has(n):
					reached.append(n)
					frontier.append(n)
		assert_eq(reached.size(), coords.size(), "%s membership is 4-connected" % id)
	assert_eq(claimed.size(), 9, "every core block belongs to exactly one district")
	# No unowned block carries a district.
	for id in loader.world.block_ids_sorted():
		var block: LandBlock = loader.world.block(id)
		if not block.is_owned():
			assert_eq(block.district_id, "", "%s has no district before READY" % id)


# --- 12. tag registry (doc 09 §7 test 9) -----------------------------------

func test_tag_registry_resolves() -> void:
	var loader := _loaded()
	var expected := ["tutorial_lot_a", "tutorial_lot_b", "tutorial_transformer", "tutorial_pump",
			"tutorial_utility_vehicle", "tutorial_expansion_block", "tutorial_substation",
			"tutorial_land_block"]
	assert_eq(loader.tags.size(), expected.size(), "the §2.9.7 registry is complete")
	for tag in expected:
		var resolved := loader.resolve_tag(tag)
		assert_false(resolved.is_empty(), "tag %s resolves to a live entity" % tag)
	assert_true(loader.resolve_tag("no_such_tag").is_empty(), "unknown tags do not resolve")

	# The two tutorial lots are vacant, buildable tiles in B_2_2.
	for tag in ["tutorial_lot_a", "tutorial_lot_b"]:
		var entry := loader.resolve_tag(tag)
		var g: Vector2i = entry["tile_global"]
		assert_true(loader.world.grid.has_flag(g.x, g.y, TileGrid.FLAG_BUILDABLE),
				"%s is buildable" % tag)
		assert_false(loader.world.grid.has_flag(g.x, g.y, TileGrid.FLAG_OCCUPIED),
				"%s is vacant" % tag)
		assert_eq(loader.world.block_of_tile(g.x, g.y).id, "B_2_2", "%s is in C3" % tag)
	assert_eq(_ints(loader.resolve_tag("tutorial_lot_a")["tile"]), [11, 8])
	assert_eq(_ints(loader.resolve_tag("tutorial_lot_b")["tile"]), [13, 8])
	assert_eq(String(loader.resolve_tag("tutorial_land_block")["id"]), "B_3_1")
	assert_eq(String(loader.resolve_tag("tutorial_expansion_block")["id"]), "B_4_3")
	assert_eq(String(loader.resolve_tag("tutorial_substation")["id"]), "SUB-A")
	assert_eq(String(loader.resolve_tag("tutorial_transformer")["id"]), "T-04")
	assert_eq(String(loader.resolve_tag("tutorial_pump")["pump"]["state"]), "offline_manual")
	assert_eq(String(loader.resolve_tag("tutorial_utility_vehicle")["home_building"]), "YARD-1")


# --- 13. data/world.json (doc 09 §8.1) -------------------------------------

func test_world_json_tunables() -> void:
	var world_data := StarterCityLoader.read_json(WORLD_PATH)
	assert_false(world_data.is_empty(), "data/world.json parses")
	assert_eq(int(world_data["schema_version"]), 2)

	var w: Dictionary = world_data["world"]
	assert_eq(_ints(w["size_blocks"]), [7, 7])
	assert_eq(_ints(w["core_origin_block"]), [2, 2])
	assert_eq(_ints(w["core_size_blocks"]), [3, 3])
	assert_eq(_ints(w["city_center_tile"]), [56, 56])
	assert_almost_eq(float(w["road_area_fraction"]), 0.34, 1e-9)
	assert_eq(int(w["reference_buildable_tiles"]), 169)
	assert_eq(String(w["grid_label_columns"]), "ABCDEFG")

	assert_eq(_ints(world_data["elevation_meters_by_class"]), [0, 5, 12, 22, 34])
	assert_eq(world_data["elevation_band_by_class"], ["LOW", "LOW", "MID", "HIGH", "HIGH"])
	var weights: Dictionary = world_data["env_risk_weights"]
	var weight_sum := 0.0
	for key in weights:
		weight_sum += float(weights[key])
	assert_almost_eq(weight_sum, 1.0, 1e-9, "env risk weights sum to 1")

	# C-61: the renamed block-level score, never doc 10's tile-level access.
	assert_true(world_data.has("block_road_access_score"))
	assert_false(world_data.has("road_access_score"), "renamed by C-61")
	assert_false(world_data.has("transformer_overload_threshold_kw"),
			"superseded by transformer_headroom_frac (§8.1)")

	var development: Dictionary = world_data["development"]
	assert_eq(Array(development["phase_order"]).size(), 6, "six development phases")
	var crew_hours: Dictionary = development["crew_hours"]
	var total_crew_hours := 0
	for phase in development["phase_order"]:
		total_crew_hours += int(crew_hours[phase])
	assert_eq(total_crew_hours, 60, "60 crew-hours per block (§2.3)")
	assert_almost_eq(float(development["first_block_time_mult"]), 0.48, 1e-9, "C-29 retune")
	assert_true(bool(development["work_units_multiply_construction_rate"]), "C-29")

	var districts: Dictionary = world_data["districts"]
	assert_eq(int(districts["max_blocks"]), 4)
	assert_almost_eq(float(districts["workforce_fraction_of_population"]), 0.55, 1e-9)
	assert_almost_eq(float(districts["district_dark_threshold"]), 0.60, 1e-9)
	var stability: Dictionary = districts["stability_weights"]
	var stability_sum := 0.0
	for key in stability:
		stability_sum += float(stability[key])
	assert_almost_eq(stability_sum, 1.0, 1e-9, "stability weights sum to 1")

	# §8.1 `starter` block must describe the emitted starter_city.json.
	var starter: Dictionary = world_data["starter"]
	assert_eq(int(starter["target_gross_tax_per_hour"]), 686)
	assert_eq(int(starter["target_population"]), 144)
	assert_eq(int(starter["target_jobs"]), 152)
	assert_eq(int(starter["target_jobs_market"]) + int(starter["target_jobs_civic"]),
			int(starter["target_jobs"]), "66 market + 86 civic = 152")
	assert_eq(int(starter["vacant_buildable_tiles"]), 1429)
	# 783.4 after Wave-4 F-4: the roster is thinner, the LOAD is conserved.
	assert_almost_eq(float(starter["night_peak_kw"]), 783.4, 0.05)
	assert_almost_eq(float(starter["water_demand_m3h"]), 5.56, 1e-9)
	assert_almost_eq(float(starter["transformer_rated_mva_total"]), 2.25, 1e-9)
	assert_almost_eq(float(starter["line_km"]), 1.42, 1e-9)
	assert_almost_eq(float(starter["t0_city_stability"]), 0.9475, 1e-9)
	assert_eq(int(starter["t0_city_level"]), 0)

	var loader := _loaded()
	var counts: Dictionary = {}
	for record in loader.buildings:
		var type_name := String(record["type"])
		counts[type_name] = int(counts.get(type_name, 0)) + 1
	var manifest: Dictionary = starter["manifest"]
	for type_name in manifest:
		assert_eq(int(counts.get(type_name, 0)), int(manifest[type_name]),
				"world.json manifest count for %s" % type_name)
	assert_eq(counts.size(), manifest.size(), "no archetype outside world.json's manifest")
	assert_eq(int(starter["vacant_buildable_tiles"]), loader.count_vacant_lots(),
			"world.json vacant lots match the stamped grid")
	var levels: Dictionary = starter["transformer_levels"]
	var counted: Dictionary = {"L1": 0, "L2": 0, "L3": 0}
	for node in loader.power_nodes_of_kind("transformer"):
		var key := "L%d" % int(node["level"])
		counted[key] = int(counted[key]) + 1
	for key in levels:
		assert_eq(int(counted[key]), int(levels[key]), "world.json transformer count %s" % key)
	var line_tiles: Dictionary = starter["line_tiles"]
	var feeder := 0
	var transmission := 0
	for line in loader.power.get("lines", []):
		if String(line["kind"]) == "feeder":
			feeder += int(line["length_tiles"])
		else:
			transmission += int(line["length_tiles"])
	assert_eq(feeder, int(line_tiles["feeder"]), "world.json feeder tiles")
	assert_eq(transmission, int(line_tiles["transmission"]), "world.json transmission tiles")


# --- 14. seed state + per-block contents (doc 09 §2.9.4, §3.1) -------------

func test_population_seed_and_per_block_contents() -> void:
	var loader := _loaded()
	assert_almost_eq(float(loader.population["attractiveness"]), 1.00, 1e-9, "A_city at t0")
	assert_almost_eq(float(loader.population["happiness"]), 82.0, 1e-9, "H at t0 (§2.10.3)")
	assert_eq(int(loader.population["building_age_hours_default"]), 36,
			"every authored building is past the occupancy ramp")

	# §2.9.4's per-block contents column, as archetype counts per block.
	var expected := {
		"B_2_2": {"construction_yard": 1, "house": 5, "apartment": 1},
		"B_3_2": {"house": 5, "apartment": 1},
		"B_4_2": {"fire_station": 1, "house": 3},
		"B_2_3": {"water_facility": 2, "house": 2},
		"B_3_3": {"office": 1, "store": 4, "apartment": 1},
		"B_4_3": {"substation": 1},
		"B_2_4": {"police_station": 1, "house": 2},
		"B_3_4": {"store": 1, "house": 1},
		"B_4_4": {"power_facility": 1},
	}
	var actual: Dictionary = {}
	for record in loader.buildings:
		var block := String(record["block"])
		if not actual.has(block):
			actual[block] = {}
		var bucket: Dictionary = actual[block]
		var type_name := String(record["type"])
		bucket[type_name] = int(bucket.get(type_name, 0)) + 1
	assert_eq(actual.size(), 9, "buildings live on all 9 core blocks")
	for block in expected:
		assert_eq(actual.get(block, {}), expected[block], "§2.9.4 contents of %s" % block)
