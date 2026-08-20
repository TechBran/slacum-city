extends SimTest
## The benchmark city — doc 09 §2.13's fixture and doc 11's use of it.
##
##   * doc 11 §7.2 **test 26** — the fixture tripwire: it exists, it parses, its
##     archetypes resolve in the mesh manifest, and it still boots.
##   * doc 11 §7.2 **test 19** — the draw-call budget regression, run at §2.5's
##     three poses against a real 1,500-building city instead of a synthetic
##     lattice.
##   * doc 09 **test 40** — the generator's own invariants, re-asserted against
##     the committed file so a hand-edit fails the build.
##
## These are the three legs of report 98 G-7's tripwire that live on this side.
## The failure mode the ruling was written about is SILENCE: a stale fixture
## makes every performance gate stop meaning anything without anything going
## red. Every assertion below exists to make that impossible.

const FIXTURE := "res://tests/fixtures/bench_city.json"
const MANIFEST := "res://game/meshes/generated/manifest.json"
const STARTER := "res://data/starter_city.json"

## Doc 11 §2.13's per-chunk opaque cost.
const CALLS_NEAR := 13
const CALLS_MEDIUM := 10
const CALLS_FAR := 3
## Building buckets re-drawn once per shadow split, NEAR chunks only.
const SHADOW_BUCKETS_PER_NEAR := 8
## §2.13's non-chunk terms: 10 vehicles + 2 weather + 4 sky/fog/glow + 25 UI.
const FIXED_CALLS := 41

const CHUNK_M := 128.0


func _fixture() -> Dictionary:
	return StarterCityLoader.read_json(FIXTURE)


func _model() -> RenderStateModel:
	return RenderStateModel.new(RenderStateModel.load_config(), "balanced")


# ------------------------------------------------------- 26 — the tripwire

func test_26_bench_fixture_exists_and_parses() -> void:
	assert_true(FileAccess.file_exists(FIXTURE),
			"tests/fixtures/bench_city.json is committed (regenerate: "
			+ "python3 tools/gen_bench_city.py)")
	var city := _fixture()
	assert_false(city.is_empty(), "and parses as a JSON object")
	# The fixture is a BOOT file in `data/starter_city.json`'s shape, not a save
	# body, so the version it must track is the loader's data-file version.
	# (Doc 09 §2.13 describes it as a save file; it is not one — see the branch
	# report's flagged doc note.)
	var starter := StarterCityLoader.read_json(STARTER)
	assert_eq(int(city.get("schema_version", -1)), int(starter.get("schema_version", -2)),
			"same data-file schema version as the city the loader was written for")
	assert_eq((city.get("blocks", []) as Array).size(), 49,
			"TileGrid.BLOCKS² block rows, or StarterCityLoader refuses it")


func test_26_every_archetype_resolves_in_the_mesh_manifest() -> void:
	var manifest: Dictionary = StarterCityLoader.read_json(MANIFEST)
	assert_false(manifest.is_empty(), "the gray-box manifest exists")
	var known: Dictionary = {}
	for entry in manifest.get("meshes", []):
		if int((entry as Dictionary).get("lod", 0)) == 0:
			known["%s:%d" % [entry["archetype"], int(entry["level"])]] = entry
	var missing: Dictionary = {}
	var footprint_mismatch: Array = []
	for raw in _fixture().get("buildings", []):
		var record: Dictionary = raw
		var key := "%s:%d" % [String(record["type"]), int(record["level"])]
		if not known.has(key):
			missing[key] = true
			continue
		# The sim stamps `size`; the renderer draws the manifest's footprint. A
		# disagreement is a building that overlaps its neighbour on screen only.
		var foot: Array = (known[key] as Dictionary)["footprint_tiles"]
		var size: Array = record["size"]
		if int(foot[0]) != int(size[0]) or int(foot[1]) != int(size[1]):
			footprint_mismatch.append("%s %s vs manifest %s" % [key, str(size), str(foot)])
	assert_eq(str(missing.keys()), str([]), "every archetype:level has a mesh")
	assert_eq(str(footprint_mismatch), str([]),
			"and the sim footprint matches the mesh footprint")


func test_26_bench_city_boots_a_sim_without_errors() -> void:
	var sim := CitySim.new()
	sim.boot(1337,
			StarterCityLoader.read_json("res://data/time.json"),
			_fixture(),
			StarterCityLoader.read_json("res://data/buildings.json"),
			StarterCityLoader.read_json("res://data/building_rules.json"),
			StarterCityLoader.read_json("res://data/grid_components.json"))
	assert_eq(str(sim.boot_errors), str(PackedStringArray()),
			"the benchmark city boots clean — every building has a transformer")
	assert_eq(sim.buildings.size(), 1500, "doc 09 §2.13's bench profile size")
	sim.scheduler.dispose()


# ------------------------------------------------- 40 — the generator's shape

func test_40_layout_invariants_hold_on_the_committed_file() -> void:
	var loader := StarterCityLoader.new()
	assert_true(loader.load_from(_fixture()),
			"the fixture loads with no errors (%s)" % str(loader.errors))
	var ready := 0
	for id in loader.world.block_ids_sorted():
		if (loader.world.block(id) as LandBlock).is_ready():
			ready += 1
	assert_eq(ready, 36, "a 6×6 developed core (doc 09 §2.13's bench profile)")

	var road_tiles := 0
	var occupied := 0
	for z in TileGrid.SIZE:
		for x in TileGrid.SIZE:
			if loader.world.grid.has_flag(x, z, TileGrid.FLAG_ROAD):
				road_tiles += 1
			if loader.world.grid.has_flag(x, z, TileGrid.FLAG_OCCUPIED):
				occupied += 1
	assert_eq(road_tiles, 36 * 87,
			"36 blocks × 87 road tiles = doc 09 §2.13's 3,132")
	assert_true(occupied > 2000, "the core is genuinely built up (%d tiles)" % occupied)

	# Nothing is stamped on a road or in the water — the two ways a generated
	# city stops being a legal one.
	for raw in _fixture().get("buildings", []):
		var record: Dictionary = raw
		var origin := StarterCityLoader.core_to_global(
				int(record["origin"][0]), int(record["origin"][1]))
		var size: Array = record["size"]
		for dz in int(size[1]):
			for dx in int(size[0]):
				var x := origin.x + dx
				var z := origin.y + dz
				assert_false(loader.world.grid.has_flag(x, z, TileGrid.FLAG_ROAD),
						"%s is on a road tile" % record["id"])
				assert_false(loader.world.grid.has_flag(x, z, TileGrid.FLAG_WATER),
						"%s is in the water" % record["id"])


func test_40_level_mix_exercises_every_lod_tier() -> void:
	var levels: Dictionary = {}
	var archetypes: Dictionary = {}
	for raw in _fixture().get("buildings", []):
		var record: Dictionary = raw
		levels[int(record["level"])] = int(levels.get(int(record["level"]), 0)) + 1
		archetypes[String(record["type"])] = true
	for level in [1, 2, 3, 4, 5]:
		assert_true(int(levels.get(level, 0)) > 0,
				"L%d is represented — a gray-box level with no instance is untested art"
				% level)
	assert_true(int(levels.get(2, 0)) + int(levels.get(3, 0)) > 800,
			"weighted toward L2–L3 as doc 09 §2.13 asks (%d + %d)"
			% [int(levels.get(2, 0)), int(levels.get(3, 0))])
	assert_true(archetypes.size() >= 10,
			"a mixed roster, not one archetype repeated (%d kinds)" % archetypes.size())


# ------------------------------------------- 19 — the draw-call budget regression

## Frustum planes for a §2.5 pose, from the engine's own projection maths rather
## than from a second copy of §2.13's trapezoid arithmetic. A test that
## re-derived the doc's formula would agree with the doc no matter what the code
## did, which is the one thing this test must not do.
func _frustum_planes(m: RenderStateModel, focus: Vector3, zoom_t: float,
		aspect: float = 16.0 / 9.0) -> Array:
	var cfg: Dictionary = m.cfg.get("camera", {})
	var eye := m.camera_position(focus, zoom_t, 0.0)
	var view := Transform3D(Basis.IDENTITY, eye).looking_at(focus, Vector3.UP)
	var projection := Projection.create_perspective(
			float(cfg.get("fov_deg", 40.0)), aspect,
			float(cfg.get("near", 1.0)), float(cfg.get("far", 1600.0)))
	# Clip-from-world, then Gribb-Hartmann row extraction. `Projection` is
	# column-major, so row `i` is (m[0][i], m[1][i], m[2][i], m[3][i]).
	var clip := projection * Projection(view.affine_inverse())
	var rows: Array[Vector4] = []
	for i in 4:
		rows.append(Vector4(clip[0][i], clip[1][i], clip[2][i], clip[3][i]))
	var planes: Array[Plane] = []
	for pair in [[0, 1.0], [0, -1.0], [1, 1.0], [1, -1.0], [2, 1.0], [2, -1.0]]:
		var a: Vector4 = rows[3] + rows[int(pair[0])] * float(pair[1])
		var normal := Vector3(a.x, a.y, a.z)
		var length := normal.length()
		if length <= 0.0:
			continue
		# Godot's `Plane(n, d)` is `n·p - d = 0`; Gribb's row is `n·p + w = 0`,
		# so `d = -w`. The normals point INWARD, so a point is inside the
		# frustum when `distance_to(p) >= 0` on all six.
		planes.append(Plane(normal / length, -a.w / length))
	return planes


static func _chunk_in_frustum(coord: Vector2i, planes: Array) -> bool:
	# The chunk's GROUND-PLANE box (§2.5): the 128 m square at y = 0, given a
	# metre of thickness so a plane lying exactly on y = 0 cannot reject it.
	var box := AABB(Vector3(float(coord.x) * CHUNK_M, -0.5, float(coord.y) * CHUNK_M),
			Vector3(CHUNK_M, 1.0, CHUNK_M))
	for plane: Plane in planes:
		# The support vertex — the corner furthest along the inward normal. If
		# even that one is outside, no part of the box is inside.
		var support := Vector3(
				box.position.x + (box.size.x if plane.normal.x > 0.0 else 0.0),
				box.position.y + (box.size.y if plane.normal.y > 0.0 else 0.0),
				box.position.z + (box.size.z if plane.normal.z > 0.0 else 0.0))
		if plane.distance_to(support) < 0.0:
			return false
	return true


## Every chunk the fixture actually populates, tiered at one pose, counted only
## where the frustum reaches.
func _census_at(pose_zoom: float) -> Dictionary:
	var m := _model()
	var loader := StarterCityLoader.new()
	loader.load_from(_fixture())
	var chunks: Dictionary = {}
	for record: Dictionary in loader.buildings:
		var origin: Vector2i = record["origin_global"]
		chunks[Vector2i(int(origin.x * 8.0 / CHUNK_M), int(origin.y * 8.0 / CHUNK_M))] = true
	var centre: Array = _fixture().get("world", {}).get("city_center_tile", [48, 48])
	var focus := Vector3(float(centre[0]) * 8.0, 0.0, float(centre[1]) * 8.0)
	var planes := _frustum_planes(m, focus, pose_zoom)
	var eye := m.camera_position(focus, pose_zoom, 0.0)
	var out := {"near": 0, "medium": 0, "far": 0, "culled": 0, "max_r": 0.0}
	var keys: Array = chunks.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return [a.y, a.x] < [b.y, b.x])
	for coord: Vector2i in keys:
		if not _chunk_in_frustum(coord, planes):
			continue
		var dist := m.chunk_ground_distance(coord, eye)
		match m.lod_for(dist, -1, 1.0):
			RenderStateModel.TIER_NEAR: out["near"] = int(out["near"]) + 1
			RenderStateModel.TIER_MEDIUM: out["medium"] = int(out["medium"]) + 1
			RenderStateModel.TIER_FAR: out["far"] = int(out["far"]) + 1
			_: out["culled"] = int(out["culled"]) + 1
		# Horizontal distance from the camera NADIR — §2.13's `r`, which the
		# phantom-row guard is stated in.
		var nearest_x := clampf(eye.x, float(coord.x) * CHUNK_M,
				float(coord.x + 1) * CHUNK_M)
		var nearest_z := clampf(eye.z, float(coord.y) * CHUNK_M,
				float(coord.y + 1) * CHUNK_M)
		var r := Vector2(nearest_x - eye.x, nearest_z - eye.z).length()
		out["max_r"] = maxf(float(out["max_r"]), r)
	return out


static func _predict(census: Dictionary, shadow_splits: int) -> int:
	var near := int(census["near"])
	return near * CALLS_NEAR + int(census["medium"]) * CALLS_MEDIUM \
			+ int(census["far"]) * CALLS_FAR \
			+ near * SHADOW_BUCKETS_PER_NEAR * shadow_splits + FIXED_CALLS


func test_19_draw_call_prediction_at_the_three_poses() -> void:
	var cfg := RenderStateModel.load_config()
	for preset_name in ["performance", "balanced", "high"]:
		var row: Dictionary = (cfg.get("presets", {}) as Dictionary)[preset_name]
		var splits := int(row.get("shadow_splits", 0))
		var budget := int(row.get("draw_call_budget", 320))
		for pose in [0.0, 0.5, 1.0]:
			var census := _census_at(pose)
			var predicted := _predict(census, splits)
			assert_true(predicted <= budget,
					"%s at zoom_t %.1f: %d predicted calls against a %d budget (%s)"
					% [preset_name, pose, predicted, budget, str(census)])


func test_19_z2_has_no_near_chunks_and_no_phantom_row() -> void:
	var census := _census_at(1.0)
	assert_eq(int(census["near"]), 0,
			"the shadow pass is EMPTY at Z2 — what makes the densest pose affordable")
	assert_true(int(census["medium"]) + int(census["far"]) > 0,
			"and the city is genuinely on screen (%s)" % str(census))
	# Report RR-12's regression guard: rows originate at 52.1 / 180 / 308 m and
	# the next would start at 436 m, beyond r_far = 411.9. Nothing may tier there.
	assert_true(float(census["max_r"]) < 436.0,
			"no chunk beyond the third row is tier-assigned at Z2 (max r = %.1f m)"
			% float(census["max_r"]))


func test_19_z2_column_arithmetic_is_the_pure_ceiling() -> void:
	# Report RR-14. `w(r) = 2·sqrt(r² + h²)·tan(hfov/2)` at h = 370.8, and each
	# row takes ⌈w(r_far_of_row)/128⌉ with NO discretionary rounding — row B is
	# 4.874 and resolves to 5, never 6.
	var h := 420.0 * sin(deg_to_rad(62.0))
	var k := tan(deg_to_rad(20.0)) * 16.0 / 9.0
	assert_almost_eq(h, 370.8, 0.05, "Z2 camera height")
	assert_almost_eq(k, 0.64706, 1e-5, "tan(hfov/2) at 16:9 from a 40° vertical")
	var expected := [5, 5, 6]
	var row_far := [180.0, 308.0, 411.9]
	for i in row_far.size():
		var w := 2.0 * sqrt(row_far[i] * row_far[i] + h * h) * k
		assert_eq(int(ceil(w / 128.0)), int(expected[i]),
				"row %s: w = %.1f m → ⌈w/128⌉ = %d" % ["ABC"[i], w, int(expected[i])])
	var cfg := RenderStateModel.load_config()
	var lod: Dictionary = cfg.get("lod", {})
	var published: Array = []
	for value in (lod.get("_z2_expected_columns_per_row", []) as Array):
		published.append(int(value))
	assert_eq(str(published), str(expected),
			"and data/render.json publishes the same split")
	assert_eq(int(lod.get("_z2_expected_chunks", 0)), 16, "5 + 5 + 6")
	assert_eq(int(lod.get("_z2_expected_draw_calls", 0)), 159,
			"10 MEDIUM × 10 + 6 FAR × 3 + 41")
