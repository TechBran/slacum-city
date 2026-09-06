extends SimTest
## **A building may not stand in the road** — doc 05 §6, doc 11 §2.14, Wave 31
## (RR-254 / RR-255 / RR-256, doc 91 A91-D-169..171).
##
## The defect, from the player, 2026-09-06: *"Treatment plants and storage tanks —
## the buildings are built off-centre, and they just fall out onto the road."*
##
## It was one join. `game/meshes/generated/manifest.json` is keyed
## `archetype:level:lod` and carries one `footprint_tiles` per archetype-level,
## and for `water_facility` that row is doc 02's own PUMP reference variant —
## `data/buildings.json` says so in a field called
## `footprints_are_reference_variant_only`. Doc 05's other placeable shells are
## not pumps: `treatment` is 2×2 at L1, `tank` is 2×2 to L2, and
## `CitySim.built_of_building` builds them on exactly that. So the renderer drew
## a 3×3 shell centred on 2×2 of ground — **4 m of building over every edge** —
## and on a lot beside a street that is a building in the road.
##
## This file holds the join shut from four directions:
##
## 1. **The manifest agrees with the catalogue.** Every mesh row's
##    `footprint_tiles` equals the footprint doc 02 (or doc 05, for a variant)
##    publishes for its (archetype, variant, level). This is the assertion that
##    makes the whole class of defect unrepeatable: a mesh authored on the wrong
##    ground fails here whoever authors it.
## 2. **Every placeable variant resolves to a shape whose mesh fits.** Walked
##    over doc 05's own `placeable` roster and every level in it, so a variant
##    that ships later cannot be forgotten.
## 3. **A variant with NO shape may still not overhang.** `booster` is the live
##    case — doc 05 §6 defers it — and the guard is a per-instance footprint
##    scale, asserted here on the number that reaches the MultiMesh buffer.
## 4. **The buckets actually split.** A tank and a pump in one chunk at one level
##    are two meshes and must be two buckets, or one of them is drawn as the
##    other whatever the manifest says.

const MESH_MANIFEST := "res://game/meshes/generated/manifest.json"
const CATALOG := "res://data/buildings.json"
const WATER := "res://data/water.json"
const RENDER := "res://data/render.json"
const TILE_M := 8.0
## The archetype every doc-05 variant hangs off (`CitySim.WATER_SHELL_ARCHETYPE`).
const SHELL := "water_facility"
## The shared LOD2 box is a mesh row with no archetype ladder behind it.
const FAR_MESH := "far_unit_box"


func _manifest() -> Dictionary:
	return StarterCityLoader.read_json(MESH_MANIFEST)


func _shapes() -> ShapeCatalog:
	return ShapeCatalog.from_manifest(_manifest())


## doc 05's `components[variant][L]` footprint columns, as
## `{variant: [Vector2i per level]}`, read the way `WaterData` reads them.
func _doc05_footprints() -> Dictionary:
	var water: Dictionary = StarterCityLoader.read_json(WATER)
	var cols: Dictionary = water.get("_component_columns", {})
	var comps: Dictionary = water.get("components", {})
	var out: Dictionary = {}
	for key: String in comps:
		var names: Array = cols.get(key, [])
		if not names.has("footprint_w"):
			continue
		var wi := names.find("footprint_w")
		var hi := names.find("footprint_h")
		var rows: Array = []
		for row_v in comps[key] as Array:
			var row: Array = row_v
			rows.append(Vector2i(int(row[wi]), int(row[hi])))
		out[key] = rows
	return out


## doc 02's own per-level footprints, `{archetype: [Vector2i per level]}`.
func _doc02_footprints() -> Dictionary:
	var catalog: Dictionary = StarterCityLoader.read_json(CATALOG).get("archetypes", {})
	var out: Dictionary = {}
	for archetype: String in catalog:
		var rows: Array = []
		for level_v in (catalog[archetype] as Dictionary).get("levels", []) as Array:
			var foot: Array = (level_v as Dictionary).get("footprint", [1, 1])
			rows.append(Vector2i(int(foot[0]), int(foot[1])))
		out[archetype] = rows
	return out


# =============================================================== 1. the join

## **The assertion the whole wave is for.** Every LOD0 mesh row's footprint is
## the footprint the CATALOGUE publishes for its (archetype, variant, level) —
## doc 02's column for a plain archetype, doc 05's for a variant. A mesh drawn on
## ground its subject does not hold cannot get past this line.
func test_every_manifest_footprint_is_its_catalogue_footprint() -> void:
	var doc02 := _doc02_footprints()
	var doc05 := _doc05_footprints()
	var checked := 0
	for entry_v in _manifest().get("meshes", []) as Array:
		var entry: Dictionary = entry_v
		var shape := String(entry.get("archetype", ""))
		if shape == FAR_MESH:
			continue
		var level := int(entry.get("level", 0))
		var foot: Array = entry.get("footprint_tiles", [])
		assert_eq(foot.size(), 2, "%s L%d has a footprint" % [shape, level])
		var mesh_foot := Vector2i(int(foot[0]), int(foot[1]))
		var variant := String(entry.get("variant", ""))
		var base := String(entry.get("variant_of", ""))
		if base == "":
			base = shape
		var want := Vector2i.ZERO
		if variant != "" and base == SHELL:
			# doc 05's own column. `source` ships subtype `river` only (§6).
			var key := "source_river" if variant == "source" else variant
			var rows: Array = doc05.get(key, [])
			assert_true(level <= rows.size(),
					"%s L%d: doc 05 has a `%s` row" % [shape, level, key])
			if level <= rows.size():
				want = rows[level - 1]
		else:
			var rows2: Array = doc02.get(base, [])
			assert_true(level <= rows2.size(),
					"%s L%d: doc 02 has a row" % [shape, level])
			if level <= rows2.size():
				want = rows2[level - 1]
		if want == Vector2i.ZERO:
			continue
		checked += 1
		assert_eq(mesh_foot, want,
				("%s L%d lod%d: the mesh is %dx%d and the catalogue says %dx%d — "
				+ "this is the shape that stands in the road")
				% [shape, level, int(entry.get("lod", 0)), mesh_foot.x, mesh_foot.y,
				want.x, want.y])
	assert_true(checked >= 160, "every mesh row was checked, not a handful (%d)" % checked)


## doc 02's `water_facility` column IS doc 05's reference-variant column (RR-8),
## which is the only reason `pump` needs no mesh of its own. Checked rather than
## repeated: if the two ever disagree, the pump is on the wrong ground too and no
## per-variant shape would have caught it.
func test_doc02s_water_column_is_doc05s_reference_variant() -> void:
	var catalog: Dictionary = StarterCityLoader.read_json(CATALOG).get("archetypes", {})
	var shell: Dictionary = catalog.get(SHELL, {})
	var reference := String(shell.get("reference_variant", ""))
	assert_eq(reference, "pump", "doc 02 names its reference variant")
	assert_true(bool(shell.get("footprints_are_reference_variant_only", false)),
			"and says out loud that its footprint column is only that variant's")
	var doc05 := _doc05_footprints()
	var rows: Array = doc05.get(reference, [])
	var doc02: Array = _doc02_footprints().get(SHELL, [])
	assert_eq(rows.size(), doc02.size(), "the two ladders are the same length")
	for i in mini(rows.size(), doc02.size()):
		assert_eq(doc02[i], rows[i],
				"water_facility L%d: doc 02 %s, doc 05 `%s` %s"
				% [i + 1, str(doc02[i]), reference, str(rows[i])])


# ================================================= 2. every placeable variant

## Every variant doc 05 lets a player build, at every level it lets them build
## it, resolves to a shape whose mesh is exactly the ground the sim gives it.
## The sim is asked — `built_of_building`'s own table — rather than the data
## file, so this is the join the renderer actually makes.
func test_every_placeable_variant_has_a_mesh_on_its_own_ground() -> void:
	var sim := CitySim.boot_from_files()
	var shapes := _shapes()
	var placeable: Dictionary = StarterCityLoader.read_json(WATER).get("placeable", {})
	var seen := 0
	for variant: String in placeable:
		if variant.begins_with("_"):
			continue
		var rules := sim.water.data.placeable_rules(variant)
		var subtype := String(rules.get("subtype", ""))
		var shape := shapes.shape_of(StringName(SHELL), StringName(variant))
		assert_true(shapes.has_own_shape(StringName(SHELL), StringName(variant)),
				"%s resolves to a mapped shape (%s), not to the fallback"
				% [variant, String(shape)])
		for level: int in (rules.get("placeable_levels", []) as Array):
			seen += 1
			var built := sim.water.data.footprint_of(StringName(variant), level, subtype)
			var mesh := shapes.footprint_of(shape, level)
			assert_eq(mesh, built,
					("%s L%d: mesh %dx%d vs built %dx%d — %+.1f m of building "
					+ "over every edge of its own lot")
					% [variant, level, mesh.x, mesh.y, built.x, built.y,
					maxf(float(mesh.x - built.x), float(mesh.y - built.y))
							* TILE_M * 0.5])
	assert_true(seen >= 8, "doc 05's whole placeable roster was walked (%d rungs)" % seen)


## The founding city's own `WTR-2` — a 2×2 `tank` on a 3×3 lot, and the subject
## of the report. It has been drawn with the pump's 3×3 shell since the city was
## authored; this is the regression pin on the exact building.
func test_the_founding_citys_own_tank_fits_its_ground() -> void:
	var sim := CitySim.boot_from_files()
	var b: Building = sim.buildings.get("WTR-2")
	assert_true(b != null, "the founding city ships WTR-2")
	if b == null:
		return
	assert_eq(String(b.variant), "tank", "and it is a tank, not a pump")
	var built := sim.built_of_building(b)
	assert_eq(built, Vector2i(2, 2), "built on 2x2 (doc 05's tank L1 column)")
	assert_eq(sim.lot_of_building(b), Vector2i(3, 3), "on a 3x3 lot (Wave 29)")
	var shapes := _shapes()
	var shape := shapes.shape_of(StringName(b.archetype), StringName(b.variant))
	assert_eq(String(shape), "water_facility_tank", "and it draws with the tank shape")
	assert_eq(shapes.footprint_of(shape, maxi(b.level, 1)), built,
			"whose mesh is its own 2x2 — no overhang, nothing in the road")
	# The number the report is about: what the ARCHETYPE key would have given.
	assert_eq(shapes.footprint_of(StringName("water_facility"), 1), Vector2i(3, 3),
			"the pump reference row it used to borrow is 3x3 — +4.0 m per edge")


# ============================================ 3. the guard, for what has none

## `booster` has no shape: doc 05 §6 defers it and nothing can place one. It must
## STILL not overhang — the archetype's mesh is squeezed into the built footprint
## instead, and this asserts the squeeze on the float that reaches the buffer.
func test_a_variant_with_no_shape_is_scaled_into_its_own_footprint() -> void:
	var model := RenderStateModel.new(StarterCityLoader.read_json(RENDER), "balanced")
	model.set_shapes(_shapes())
	assert_false(model.shapes().has_own_shape(StringName(SHELL), &"booster"),
			"booster is the live no-shape case")
	# doc 05's booster L1 is 1x1 and the archetype's mesh is the pump's 3x3.
	var scale := model.footprint_scale_for(StringName(SHELL), 1, Vector2i.ONE)
	assert_almost_eq(scale.x, 1.0 / 3.0, 1e-5, "1x1 of ground out of a 3x3 mesh")
	assert_almost_eq(scale.y, 1.0 / 3.0, 1e-5, "on both axes")
	model.add_building({
		"id": 1, "archetype_id": StringName(SHELL), "variant_id": &"booster",
		"level": 1, "family": "civic", "world_pos": Vector3(20.0, 0.0, 20.0),
		"built_tiles": Vector2i.ONE,
		"transform": Transform3D(Basis.IDENTITY, Vector3(20.0, 0.0, 20.0)),
	})
	var rec := model.building(1)
	assert_true(rec != null, "the shell is in the model")
	if rec == null:
		return
	var half_x: float = 3.0 * TILE_M * 0.5 * rec.transform.basis.x.x
	assert_almost_eq(half_x, TILE_M * 0.5, 1e-4,
			"the drawn half-extent is 4 m — the 1x1 tile it stands on, not 12 m")
	assert_almost_eq(rec.transform.basis.y.y, 1.0, 1e-6,
			"and the HEIGHT is untouched: the construction clamp is written "
			+ "against the archetype's own build_height_m")


## The guard only ever shrinks. A mesh SMALLER than the ground is a building with
## room around it — which is what §2.16a's lot dressing is for — and inflating
## the art to fill a lot would be a different lie.
func test_the_guard_never_enlarges() -> void:
	var model := RenderStateModel.new(StarterCityLoader.read_json(RENDER), "balanced")
	model.set_shapes(_shapes())
	var scale := model.footprint_scale_for(StringName("house"), 1, Vector2i(4, 4))
	assert_eq(scale, Vector2.ONE, "a 1x1 house on 4x4 of ground stays 1x1")
	assert_eq(model.footprint_scale_for(StringName("house"), 1, Vector2i.ZERO),
			Vector2.ONE, "and a view that says nothing about its ground changes nothing")


# ================================================== 4. the buckets, and growth

## A tank and a pump at the same level in the same chunk are two meshes, so they
## must be two buckets. Keyed by archetype they were ONE, and whichever mesh the
## bucket was created with drew both.
func test_two_water_variants_in_one_chunk_are_two_buckets() -> void:
	var model := RenderStateModel.new(StarterCityLoader.read_json(RENDER), "balanced")
	model.set_shapes(_shapes())
	var here := Vector3(24.0, 0.0, 24.0)
	for spec in [[1, &"pump"], [2, &"tank"]]:
		model.add_building({
			"id": int(spec[0]), "archetype_id": StringName(SHELL),
			"variant_id": spec[1], "level": 1, "family": "civic",
			"world_pos": here, "built_tiles": Vector2i(2, 2),
			"transform": Transform3D(Basis.IDENTITY, here),
		})
	var chunk := model.chunk_of(here)
	assert_eq(model.buckets_of(chunk).size(), 2,
			"one bucket per SHAPE, not one per archetype")
	var pump := model.bucket(chunk, &"water_facility", 1)
	var tank := model.bucket(chunk, &"water_facility_tank", 1)
	assert_true(pump != null and tank != null, "and both are addressable")
	if pump == null or tank == null:
		return
	assert_eq(pump.visible_count, 1, "the pump has its own instance")
	assert_eq(tank.visible_count, 1, "and so does the tank")
	assert_eq(String(tank.archetype), SHELL,
			"the tank bucket still WEARS water_facility — its texture pages are "
			+ "the waterworks', not a fifteenth archetype's")


## A completed rung that GROWS the footprint moves the building's centre, because
## a mesh is centred on the ground it holds. The model rebucketed the level and
## left the transform where the old rung put it, standing every grown building
## 4 m off its own lot (RR-255).
func test_a_grown_rung_is_recentred_on_its_new_ground() -> void:
	var model := RenderStateModel.new(StarterCityLoader.read_json(RENDER), "balanced")
	model.set_shapes(_shapes())
	# doc 05's treatment: 2x2 at L1, 3x3 at L2. Origin (0,0) → centre (8,0,8)
	# then (12,0,12).
	var l1_centre := TileGrid.centre_of_footprint(Vector2i.ZERO, Vector2i(2, 2))
	model.add_building({
		"id": 7, "archetype_id": StringName(SHELL), "variant_id": &"treatment",
		"level": 1, "family": "civic", "world_pos": l1_centre,
		"built_tiles": Vector2i(2, 2),
		"transform": Transform3D(Basis.IDENTITY, l1_centre),
	})
	var l2_centre := TileGrid.centre_of_footprint(Vector2i.ZERO, Vector2i(3, 3))
	model.apply_events([{"type": &"building_completed", "building": 7, "level": 2,
			"world_pos": l2_centre, "built_tiles": Vector2i(3, 3)}])
	var rec := model.building(7)
	assert_true(rec != null, "the plant is still in the model")
	if rec == null:
		return
	assert_eq(rec.level, 2, "it climbed")
	assert_eq(rec.transform.origin, l2_centre,
			"and it MOVED: a 3x3 centre is 4 m along both axes from a 2x2 one")
	assert_eq(rec.built_tiles, Vector2i(3, 3), "on the ground the new rung holds")
	assert_eq(_shapes().footprint_of(rec.shape, 2), Vector2i(3, 3),
			"and the L2 mesh is that ground")


## An event with no geometry on it changes no geometry — the arm every other
## producer in the project still uses.
func test_a_completion_without_geometry_leaves_the_transform_alone() -> void:
	var model := RenderStateModel.new(StarterCityLoader.read_json(RENDER), "balanced")
	model.set_shapes(_shapes())
	var here := Vector3(40.0, 0.0, 40.0)
	model.add_building({
		"id": 9, "archetype_id": &"store", "level": 1, "family": "commercial",
		"world_pos": here, "built_tiles": Vector2i.ONE,
		"transform": Transform3D(Basis.IDENTITY, here),
	})
	model.apply_events([{"type": &"building_completed", "building": 9, "level": 3}])
	var rec := model.building(9)
	assert_true(rec != null, "the store survives")
	if rec == null:
		return
	assert_eq(rec.level, 3, "the level moved")
	assert_eq(rec.transform.origin, here, "and the centre did not, having been told nothing")
