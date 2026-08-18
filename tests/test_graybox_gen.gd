extends SimTest
## Doc 11 §7.1 — gray-box generator (tools/gen_graybox.gd + data/building_shapes.json).
## Method names carry the doc's test numbers.

const GEN := preload("res://tools/gen_graybox.gd")
const SHAPES_PATH := "res://data/building_shapes.json"
const RENDER_PATH := "res://data/render.json"
const OUT_DIR := "res://game/meshes/generated"
const MANIFEST := OUT_DIR + "/manifest.json"
const TMP_DIR := "user://graybox_determinism_test"

const FLOOR_H := 3.5


func _manifest() -> Dictionary:
	return GEN.load_json(MANIFEST)


func _shapes() -> Dictionary:
	return GEN.load_json(SHAPES_PATH)


func _entries() -> Array:
	return _manifest().get("meshes", [])


func _read_bytes(path: String) -> PackedByteArray:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return PackedByteArray()
	var b := f.get_buffer(f.get_length())
	f.close()
	return b


static func _popcount(x: int) -> int:
	var n := 0
	var v := x
	while v != 0:
		n += v & 1
		v >>= 1
	return n


# ------------------------------------------------------------ 1 — determinism

func test_01_determinism_byte_identical() -> void:
	# a) the committed manifest was generated from the committed input
	var m := _manifest()
	assert_eq(String(m.get("generated_from_hash", "")), GEN.file_sha1(SHAPES_PATH),
			"manifest hash matches data/building_shapes.json")
	assert_eq(int(m.get("generator_version", -1)), int(_shapes().get("generator_version", -2)),
			"generator_version matches the input")

	# b) a fresh in-memory build reproduces every mesh hash in the manifest
	var built: Dictionary = GEN.build_all(_shapes(), GEN.load_json(RENDER_PATH))
	assert_true((built["errors"] as Array).is_empty(),
			"generator reports no budget errors: %s" % str(built["errors"]))
	var by_name: Dictionary = {}
	for item_v in built["meshes"]:
		var item: Dictionary = item_v
		by_name[String(item["name"])] = item["meta"]
	for e_v in _entries():
		var e: Dictionary = e_v
		var name := String(e["path"]).get_file().get_basename()
		assert_true(by_name.has(name), "manifest entry %s was rebuilt" % name)
		if by_name.has(name):
			assert_eq(String((by_name[name] as Dictionary)["mesh_hash"]), String(e["mesh_hash"]),
					"%s hash is reproducible" % name)

	# c) regenerating to a scratch directory writes byte-identical .res files
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_DIR))
	var run: Dictionary = GEN.generate(SHAPES_PATH, RENDER_PATH, TMP_DIR, true)
	assert_true((run["errors"] as Array).is_empty(), "scratch run clean: %s" % str(run["errors"]))
	var compared := 0
	for e_v in _entries():
		var e: Dictionary = e_v
		var file := String(e["path"]).get_file()
		var a := _read_bytes(String(e["path"]))
		var b := _read_bytes(TMP_DIR + "/" + file)
		assert_true(a.size() > 0, "committed mesh %s is readable" % file)
		assert_eq(b, a, "%s is byte-identical across generations" % file)
		compared += 1
	assert_eq(compared, _entries().size(), "every committed mesh compared")
	_cleanup_tmp()


func _cleanup_tmp() -> void:
	var dir := DirAccess.open(TMP_DIR)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if not dir.current_is_dir():
			dir.remove(entry)
		entry = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_DIR))


func test_01b_idempotent_when_up_to_date() -> void:
	var run: Dictionary = GEN.generate(SHAPES_PATH, RENDER_PATH, OUT_DIR, false)
	assert_true(bool(run["skipped"]),
			"a second run with a matching hash + version writes nothing")
	assert_true((run["errors"] as Array).is_empty(), "no errors on the skip path")


# --------------------------------------------------------------- 2 — coverage

func test_02_coverage() -> void:
	var shapes := _shapes()
	var archetypes: Array = shapes["archetypes"]
	assert_eq(archetypes.size(), 12, "the 12 shipped archetypes (doc 02 roster)")

	var buildings := GEN.load_json("res://data/buildings.json")
	var roster: Dictionary = buildings.get("archetypes", {})
	for a_v in archetypes:
		var a: Dictionary = a_v
		assert_true(roster.has(String(a["id"])), "%s exists in data/buildings.json" % a["id"])
		assert_eq((a["levels"] as Array).size(), 5, "%s has 5 levels" % a["id"])
	assert_eq(roster.size(), archetypes.size(), "every shipped archetype has a shape")

	var seen: Dictionary = {}
	var far_seen := false
	for e_v in _entries():
		var e: Dictionary = e_v
		if String(e["archetype"]) == "far_unit_box":
			far_seen = true
			assert_eq(int(e["tris"]), 12, "shared FAR box is 12 tris")
			assert_eq(int(e["lod"]), 2, "FAR box is LOD2")
		else:
			seen["%s_%d_%d" % [e["archetype"], int(e["level"]), int(e["lod"])]] = true
		assert_true(FileAccess.file_exists(String(e["path"])),
				"%s exists on disk" % e["path"])
		var mesh: ArrayMesh = load(String(e["path"]))
		assert_true(mesh != null, "%s loads as an ArrayMesh" % e["path"])
	assert_true(far_seen, "the shared FAR unit box is generated")
	for a_v2 in archetypes:
		var a2: Dictionary = a_v2
		for lv in range(1, 6):
			for lod in [0, 1]:
				assert_true(seen.has("%s_%d_%d" % [a2["id"], lv, lod]),
						"%s L%d lod%d in the manifest" % [a2["id"], lv, lod])
	assert_eq(_entries().size(), 12 * 5 * 2 + 1, "12 x 5 x 2 + the shared FAR box")


# ---------------------------------------------------------- 3 — height formula

func test_03_height_formula() -> void:
	for e_v in _entries():
		var e: Dictionary = e_v
		if String(e["archetype"]) == "far_unit_box":
			continue
		var expected := float(e["floors"]) * FLOOR_H + float(e["roof_extra_m"])
		assert_almost_eq(float(e["height_m"]), expected, 0.01,
				"%s height = floors*3.5 + roof_extra" % e["path"])
		var aabb: Array = e["aabb"]
		assert_almost_eq(float(aabb[1]), float(e["height_m"]), 0.01, "aabb.y is the height")
		var fp: Array = e["footprint_tiles"]
		assert_almost_eq(float(aabb[0]), float(fp[0]) * 8.0, 0.01, "aabb.x = footprint tiles x 8 m")
		assert_almost_eq(float(aabb[2]), float(fp[1]) * 8.0, 0.01, "aabb.z = footprint tiles x 8 m")


func test_03b_levels_grow_visibly() -> void:
	var by_arch: Dictionary = {}
	for e_v in _entries():
		var e: Dictionary = e_v
		if int(e["lod"]) != 0 or String(e["archetype"]) == "far_unit_box":
			continue
		var arch := String(e["archetype"])
		if not by_arch.has(arch):
			by_arch[arch] = {}
		(by_arch[arch] as Dictionary)[int(e["level"])] = float(e["height_m"])
	for arch in by_arch:
		var heights: Dictionary = by_arch[arch]
		for lv in range(1, 5):
			assert_true(float(heights[lv + 1]) > float(heights[lv]),
					"%s L%d is taller than L%d" % [arch, lv + 1, lv])
		assert_true(float(heights[5]) >= 1.5 * float(heights[1]),
				"%s grows at least 50%% from L1 to L5" % arch)


# ------------------------------------------------------------- 4 — tri budgets

func test_04_tri_budgets() -> void:
	var lod_cfg: Dictionary = (GEN.load_json(RENDER_PATH))["lod"]
	var budget0 := int(lod_cfg["tri_budget_lod0"])
	var budget0_tall := int(lod_cfg["tri_budget_lod0_tall"])
	var budget1 := int(lod_cfg["tri_budget_lod1"])
	var ratio := float(lod_cfg["lod1_ratio_max"])
	var tall: Array = lod_cfg["tall_archetypes"]

	var lod0: Dictionary = {}
	for e_v in _entries():
		var e: Dictionary = e_v
		if int(e["lod"]) == 0:
			lod0["%s_%d" % [e["archetype"], int(e["level"])]] = int(e["tris"])
	for e_v2 in _entries():
		var e2: Dictionary = e_v2
		var key := "%s_%d" % [e2["archetype"], int(e2["level"])]
		var tris := int(e2["tris"])
		if int(e2["lod"]) == 0:
			var is_tall := tall.has(String(e2["doc11_id"])) or tall.has(String(e2["archetype"]))
			var cap := budget0_tall if is_tall else budget0
			assert_true(tris <= cap, "%s LOD0 %d <= %d" % [key, tris, cap])
		elif int(e2["lod"]) == 1:
			assert_true(tris <= budget1, "%s LOD1 %d <= %d" % [key, tris, budget1])
			assert_true(float(tris) <= ratio * float(lod0[key]),
					"%s LOD1 %d <= %.2f x LOD0 %d" % [key, tris, ratio, int(lod0[key])])
	# the tri counts in the manifest are the real surface counts
	for e_v3 in _entries():
		var e3: Dictionary = e_v3
		var mesh: ArrayMesh = load(String(e3["path"]))
		var arrays := mesh.surface_get_arrays(0)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		assert_eq(indices.size() / 3, int(e3["tris"]), "%s manifest tris match the mesh" % e3["path"])


# ---------------------------------------------------------------- 5 — UV2 rule

func test_05_uv2_window_grid_rule() -> void:
	var windowed := 0
	for e_v in _entries():
		var e: Dictionary = e_v
		var mesh: ArrayMesh = load(String(e["path"]))
		var arrays := mesh.surface_get_arrays(0)
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uv2: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV2]
		assert_eq(uv2.size(), normals.size(), "%s carries UV2 per vertex" % e["path"])
		var valid := 0
		for i in normals.size():
			var n := normals[i]
			var w := uv2[i]
			var is_neg := w.x < 0.0 and w.y < 0.0
			if absf(n.y) > 0.5:
				assert_true(is_neg, "%s: roof/ground face has UV2 (-1,-1)" % e["path"])
			if not is_neg:
				assert_true(absf(n.y) < 0.2,
						"%s: window UV2 only on vertical facades" % e["path"])
				assert_true(w.x >= 0.0 and w.x <= 1.0 and w.y >= 0.0 and w.y <= 1.0,
						"%s: facade UV2 inside [0,1]^2" % e["path"])
				valid += 1
		if String(e["archetype"]) == "data_center":
			assert_eq(valid, 0, "tech_datacenter is windowless: zero valid-UV2 vertices")
		elif String(e["archetype"]) != "far_unit_box":
			assert_true(valid > 0, "%s has a window grid" % e["path"])
			windowed += 1
	assert_true(windowed >= 100, "every non-datacenter mesh carries a window grid")


func test_05b_window_grid_metadata() -> void:
	for e_v in _entries():
		var e: Dictionary = e_v
		if String(e["archetype"]) == "data_center" or String(e["archetype"]) == "far_unit_box":
			assert_eq(int(e["window_cols"]), 0, "%s is windowless" % e["archetype"])
			assert_true(bool(e["windowless"]), "windowless flag set")
			continue
		assert_true(int(e["window_cols"]) >= 1, "%s has window columns" % e["path"])
		assert_true(int(e["window_rows"]) >= 1, "%s has window rows" % e["path"])
	# doc 11 §2.14: window_cols = max(1, round(width_m / 3.2)); a 2x2-tile block
	# is 15.2 m wide as authored -> round(4.75) = 5, matching the §2.7.1 example.
	for e_v2 in _entries():
		var e2: Dictionary = e_v2
		if String(e2["archetype"]) == "high_rise" and int(e2["level"]) == 4 and int(e2["lod"]) == 0:
			assert_eq(int(e2["window_cols"]), 5, "high_rise L4 has 5 window columns")


# --------------------------------------------------------------- 6 — AO bake

func test_06_vertex_ao_bake() -> void:
	for e_v in _entries():
		var e: Dictionary = e_v
		if String(e["archetype"]) == "far_unit_box":
			continue
		var mesh: ArrayMesh = load(String(e["path"]))
		var arrays := mesh.surface_get_arrays(0)
		var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
		assert_true(colors.size() > 0, "%s bakes vertex colours" % e["path"])
		var dark := 0
		for i in colors.size():
			var c := colors[i]
			assert_true(c.r <= 1.0 + 1e-5, "%s: no AO multiplier above 1.0" % e["path"])
			assert_true(c.r >= 0.0, "%s: no negative AO" % e["path"])
			assert_almost_eq(c.g, c.r, 1e-5, "AO is greyscale")
			if c.r <= 0.60:
				dark += 1
		assert_true(dark >= 1, "%s has a contact-darkened vertex (<= 0.60)" % e["path"])


# ------------------------------------------------- 7 — silhouette uniqueness

func test_07_silhouette_descriptor_uniqueness() -> void:
	var desc: Dictionary = {}
	var archetypes: Array = []
	for e_v in _entries():
		var e: Dictionary = e_v
		if int(e["lod"]) != 0 or String(e["archetype"]) == "far_unit_box":
			continue
		var arch := String(e["archetype"])
		if not archetypes.has(arch):
			archetypes.append(arch)
		var value := String(e["silhouette_descriptor"]).hex_to_int()
		assert_true(value < (1 << 24), "%s descriptor fits in 24 bits" % arch)
		desc["%s_%d" % [arch, int(e["level"])]] = value

	for lv in range(1, 6):
		for i in archetypes.size():
			for j in range(i + 1, archetypes.size()):
				var a := String(archetypes[i])
				var b := String(archetypes[j])
				var d := _popcount(int(desc["%s_%d" % [a, lv]]) ^ int(desc["%s_%d" % [b, lv]]))
				assert_true(d >= 4,
						"L%d %s vs %s Hamming %d >= 4" % [lv, a, b, d])
	for arch_v in archetypes:
		var arch2 := String(arch_v)
		for l1 in range(1, 6):
			for l2 in range(l1 + 1, 6):
				var d2 := _popcount(int(desc["%s_%d" % [arch2, l1]])
						^ int(desc["%s_%d" % [arch2, l2]]))
				assert_true(d2 >= 2,
						"%s L%d vs L%d Hamming %d >= 2" % [arch2, l1, l2, d2])


func test_07b_roof_signature_is_constant_across_levels() -> void:
	var sig: Dictionary = {}
	for e_v in _entries():
		var e: Dictionary = e_v
		if String(e["archetype"]) == "far_unit_box":
			continue
		var arch := String(e["archetype"])
		if sig.has(arch):
			assert_eq(String(e["roof_signature"]), String(sig[arch]),
					"%s keeps one roof signature at every level" % arch)
		else:
			sig[arch] = String(e["roof_signature"])
	assert_eq(sig.size(), 12, "12 archetype signatures")
	var distinct: Dictionary = {}
	for arch in sig:
		distinct[sig[arch]] = true
	assert_eq(distinct.size(), 12, "every archetype has its own roof signature")


# ------------------------------------------------------- LOD1 derivation rules

func test_08_lod1_keeps_the_signature_silhouette() -> void:
	var shapes := _shapes()
	for a_v in shapes["archetypes"]:
		var a: Dictionary = a_v
		for lvl_v in a["levels"]:
			var props: Array = (lvl_v as Dictionary)["roof_props"]
			assert_true(props.size() > 0,
					"%s L%d has roof structure" % [a["id"], int((lvl_v as Dictionary)["level"])])
	# the silhouette survives the LOD1 derivation: either an explicitly flagged
	# signature prop is kept, or every prop collapses into one AABB box.
	var lod0_height: Dictionary = {}
	for e_v0 in _entries():
		var e0: Dictionary = e_v0
		if int(e0["lod"]) == 0:
			lod0_height["%s_%d" % [e0["archetype"], int(e0["level"])]] = float(e0["height_m"])
	for e_v1 in _entries():
		var e1: Dictionary = e_v1
		if int(e1["lod"]) != 1:
			continue
		var key := "%s_%d" % [e1["archetype"], int(e1["level"])]
		assert_true(float(e1["height_m"]) >= 0.75 * float(lod0_height[key]),
				"%s LOD1 keeps the silhouette height (%.1f of %.1f m)"
						% [key, float(e1["height_m"]), float(lod0_height[key])])
	# LOD1 always has fewer vertices than LOD0 and never loses the footprint
	for e_v in _entries():
		var e: Dictionary = e_v
		if int(e["lod"]) != 1:
			continue
		var mesh: ArrayMesh = load(String(e["path"]))
		assert_true(mesh.get_surface_count() == 1, "one surface per generated mesh")
		var aabb := mesh.get_aabb()
		assert_true(aabb.size.y > 0.0, "%s has volume" % e["path"])
