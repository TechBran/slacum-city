extends SimTest
## THE ASSET MATRIX — doc 91 §16's "textures on everything" half, as a gate.
##
## Every other asset test in this tree examines one family in depth:
## `test_graybox_gen` holds the generator to its own rules, `test_building_textures`
## holds the façade pages to the emissive grid, `test_vehicle_view` holds the
## fleet to its triangle budget, `test_power_infra` holds the pads to doc 04's
## bands. None of them asks the question this file exists for, and it is the
## question the standing directive asks:
##
##   **Is there a mesh and a surface for every row of every roster the game
##   ships — and would a new row without one be noticed?**
##
## That is a different shape of test. It is a JOIN, not a depth probe: the
## rosters are the authored tables (`data/buildings.json`, `data/vehicles.json`,
## the texture and mesh manifests, `data/render.json`), and each row of each
## roster has to land on an asset that exists, loads, carries geometry, and
## resolves a page. A **thirteenth** archetype, a **sixth** vehicle type or a
## **nineteenth** texture page arrives in this file's failure output on the day
## it is authored, rather than in a playtest three weeks later.
##
## The class of defect it exists to catch is one this project has already
## shipped twice: doc 91 §4's *"a subsystem can be fully shipped and wholly
## invisible"* (doc 04's whole distribution end, drawn by nothing until Wave 10),
## and the pump station that bought a blank tile because its placement event had
## no arm in the shell's translator (2026-08-20). Both were found by a person
## looking at a screen. Neither had to be.
##
## Failure messages name the CELL, never just the assertion, because the whole
## value of a matrix is knowing which cell of it is empty.
##
## Read-only. Nothing here mutates a resource, writes a file, or touches a sim.

const MESH_MANIFEST := "res://game/meshes/generated/manifest.json"
const TEX_MANIFEST := "res://game/textures/generated/manifest.json"
const CATALOG := "res://data/buildings.json"
const SHAPES := "res://data/building_shapes.json"
const RENDER_JSON := "res://data/render.json"
const VEHICLES := "res://data/vehicles.json"
const SHADER_DIR := "res://game/shaders"

## The shared FAR box is a mesh row without an archetype; it is checked on its
## own terms (test 08) and skipped by every per-archetype sweep.
const FAR_MESH := "far_unit_box"

## `CityView.FAMILY_ORDER`, restated. A family the renderer does not know falls
## back to index 0 — residential window colour on a civic tower — silently, in
## one `maxi(idx, 0)` at `city_view.gd:192`. Restating the list here is what
## turns that silence into a failure.
const FAMILY_ORDER := ["residential", "commercial", "industrial", "tech", "civic"]

## Every shader the shipped renderer owns. A `.gdshader` that stops being
## referenced is either dead weight or a layer that quietly lost its material.
const SHADERS := [
	"building.gdshader", "building_far.gdshader", "construction_rig.gdshader",
	"flood.gdshader", "ground.gdshader", "lamp.gdshader", "light_pool.gdshader",
	"power_pad.gdshader", "power_smoke.gdshader", "power_wire.gdshader",
	"road_overlay.gdshader", "road_surface.gdshader", "sidewalk.gdshader",
	"sky_gradient.gdshader",
	"street_fx.gdshader", "street_life.gdshader",
	"vehicle.gdshader", "vehicle_headlight.gdshader", "water.gdshader",
]

## Where each shader is expected to be reachable from. One entry per row of
## SHADERS; the sweep asserts the named file mentions the shader by path.
const SHADER_OWNER := {
	"building.gdshader": "res://game/render/city_view.gd",
	"building_far.gdshader": "res://game/render/city_view.gd",
	"construction_rig.gdshader": "res://game/render/construction_vehicle_view.gd",
	"flood.gdshader": "res://game/render/flood_view.gd",
	"ground.gdshader": "res://game/render/ground_surface.gd",
	"lamp.gdshader": "res://game/render/streetlight_view.gd",
	"light_pool.gdshader": "res://game/render/streetlight_view.gd",
	"power_pad.gdshader": "res://game/render/power_infra_view.gd",
	"power_smoke.gdshader": "res://game/render/power_infra_view.gd",
	"power_wire.gdshader": "res://game/render/power_infra_view.gd",
	"road_overlay.gdshader": "res://game/render/road_overlay_view.gd",
	"road_surface.gdshader": "res://game/render/road_surface_view.gd",
	"sidewalk.gdshader": "res://game/render/road_surface_view.gd",
	# Wave 17's sky is the one shader whose owner is not a `game/render/` view:
	# `EnvironmentController` installs it on the `Environment`'s `Sky`, which is
	# where every other environment write already lives (doc 11 §2.8).
	"sky_gradient.gdshader": "res://game/environment_controller.gd",
	"street_fx.gdshader": "res://game/render/street_life_view.gd",
	"street_life.gdshader": "res://game/render/street_life_view.gd",
	"vehicle.gdshader": "res://game/render/vehicle_view.gd",
	"vehicle_headlight.gdshader": "res://game/render/vehicle_view.gd",
	"water.gdshader": "res://game/render/ground_surface.gd",
}

## `game/textures/generated/manifest.json` groups, and the class that reads each
## one. A page group with no reader is a page nobody wears.
const PAGE_GROUP_READER := {
	"facades": "res://game/render/city_view.gd",
	"roofs": "res://game/render/city_view.gd",
	"grounds": "res://game/render/ground_surface.gd",
	"props": "res://game/render/prop_surface.gd",
	"vehicles": "res://game/render/vehicle_view.gd",
}

## Doc 02 §2.14: six archetypes carry a level 6, the rest stop at 5. Restated
## so a roster that silently loses a rung fails here as well as in the catalog.
const LEVELS_EXPECTED := {
	"house": 6, "apartment": 6, "store": 6, "office": 6, "high_rise": 6,
	"data_center": 6, "police_station": 5, "fire_station": 5,
	"power_facility": 5, "substation": 5, "water_facility": 5,
	"construction_yard": 5,
}

## `data/vehicles.json` has no `medical` department and doc 06 §6 DEFERS EMS, so
## `VehicleMesh.ambulance()` is a body the sim can never ask for. It is a real
## asset and it is unreachable; doc 91 A91-D-20 carries it. Listed here so the
## roster join can be exact rather than lenient — the day a `medical` type is
## authored, this constant is what has to be deleted.
const DEFERRED_BODIES := ["ambulance"]


# ------------------------------------------------------------------ fixtures

func _meshes() -> Array:
	return StarterCityLoader.read_json(MESH_MANIFEST).get("meshes", [])


func _tex() -> Dictionary:
	return StarterCityLoader.read_json(TEX_MANIFEST)


func _catalog() -> Dictionary:
	return StarterCityLoader.read_json(CATALOG).get("archetypes", {})


func _render() -> Dictionary:
	return StarterCityLoader.read_json(RENDER_JSON)


func _text_of(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	return FileAccess.get_file_as_string(path)


## The matrix itself: `"archetype:level:lod"` -> the manifest row.
func _cells() -> Dictionary:
	var out: Dictionary = {}
	for raw: Variant in _meshes():
		var e: Dictionary = raw
		if String(e.get("archetype", "")) == FAR_MESH:
			continue
		out["%s:%d:%d" % [String(e["archetype"]), int(e["level"]), int(e["lod"])]] = e
	return out


## Which pages an archetype wears — `CityView._surface_for`, restated.
func _surface_for(archetype: String, family: String) -> Dictionary:
	var tex := _tex()
	var by_arch: Dictionary = tex.get("archetype_surface", {})
	if by_arch.has(archetype):
		return by_arch[archetype]
	return (tex.get("family_surface", {}) as Dictionary).get(family, {})


# ------------------------------------------------- 1 — the roster join itself

func test_01_every_catalog_cell_has_a_mesh_at_both_lods() -> void:
	# The join that makes this file a matrix: every (archetype, level) the SIM
	# can instantiate must have a LOD0 and a LOD1 the RENDERER can draw. A rung
	# added to `data/buildings.json` without a re-run of `tools/gen_graybox.gd`
	# lands here.
	var cells := _cells()
	var catalog := _catalog()
	assert_eq(catalog.size(), 12, "doc 02 §2.1's roster is twelve archetypes")
	var counted := 0
	for archetype: String in catalog:
		var levels: Array = (catalog[archetype] as Dictionary).get("levels", [])
		assert_eq(levels.size(), int(LEVELS_EXPECTED.get(archetype, 0)),
				"%s: doc 02 §2.14 rungs" % archetype)
		for raw: Variant in levels:
			var level := int((raw as Dictionary)["level"])
			for lod in [0, 1]:
				var key := "%s:%d:%d" % [archetype, level, lod]
				assert_true(cells.has(key),
						"NO MESH for cell %s — re-run tools/gen_graybox.gd" % key)
				counted += 1
	# 12 archetypes: 6 at six rungs + 6 at five = 66 cells, 132 with both LODs.
	assert_eq(counted, 132, "the building matrix is 132 cells")
	assert_eq(cells.size(), 132,
			"the manifest holds exactly the matrix and no orphan rows")


func test_02_every_cell_loads_as_a_mesh_with_geometry() -> void:
	# "The file is in the manifest" and "the file is on disk and has triangles"
	# are different claims, and a `.res` that failed to import is silently the
	# second kind of missing.
	for key: String in _cells():
		var e: Dictionary = _cells()[key]
		var path := String(e["path"])
		assert_true(ResourceLoader.exists(path), "%s: %s is not on disk" % [key, path])
		if not ResourceLoader.exists(path):
			continue
		var mesh: ArrayMesh = load(path)
		assert_true(mesh != null, "%s: %s did not load" % [key, path])
		if mesh == null:
			continue
		assert_eq(mesh.get_surface_count(), 1, "%s: one surface per gray-box" % key)
		var arrays := mesh.surface_get_arrays(0)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		assert_true(indices.size() >= 3, "%s: mesh has no triangles" % key)
		assert_eq(indices.size() / 3, int(e["tris"]),
				"%s: manifest says %d tris, mesh has %d"
				% [key, int(e["tris"]), indices.size() / 3])


func test_03_tri_counts_are_sane_and_inside_the_authored_budget() -> void:
	# Doc 11 §11's budgets, joined per cell rather than per entry, so the
	# message names the cell that blew it.
	var lod: Dictionary = _render()["lod"]
	var cap0 := int(lod["tri_budget_lod0"])
	var cap0_tall := int(lod["tri_budget_lod0_tall"])
	var cap1 := int(lod["tri_budget_lod1"])
	var tall: Array = lod["tall_archetypes"]
	var cells := _cells()
	for key: String in cells:
		var e: Dictionary = cells[key]
		var tris := int(e["tris"])
		assert_true(tris > 0, "%s: zero triangles is not a gray box" % key)
		if int(e["lod"]) == 0:
			var is_tall: bool = tall.has(String(e.get("doc11_id", ""))) \
					or tall.has(String(e["archetype"]))
			var cap := cap0_tall if is_tall else cap0
			assert_true(tris <= cap, "%s: LOD0 %d tris over the %d budget"
					% [key, tris, cap])
		else:
			assert_true(tris <= cap1, "%s: LOD1 %d tris over the %d budget"
					% [key, tris, cap1])


# --------------------------------------------- 2 — textures on everything

func test_04_every_cell_resolves_a_facade_and_a_roof_page_that_loads() -> void:
	# The "textures on everything" clause, taken literally and per cell. A new
	# archetype whose family is unmapped resolves to `{}` in `_surface_for` and
	# draws untextured at `tex_mix = 0` — legal, and wrong.
	var tex := _tex()
	var facades: Dictionary = tex.get("facades", {})
	var roofs: Dictionary = tex.get("roofs", {})
	var cells := _cells()
	for key: String in cells:
		var e: Dictionary = cells[key]
		var archetype := String(e["archetype"])
		var family := String(e.get("family", ""))
		var surface := _surface_for(archetype, family)
		assert_false(surface.is_empty(),
				"%s: no facade/roof mapping for archetype %s or family %s"
				% [key, archetype, family])
		if surface.is_empty():
			continue
		var facade := String(surface.get("facade", ""))
		var roof := String(surface.get("roof", ""))
		assert_true(facades.has(facade), "%s: facade page '%s' is not declared"
				% [key, facade])
		assert_true(roofs.has(roof), "%s: roof page '%s' is not declared" % [key, roof])
		for page: String in [facade, roof]:
			var group: Dictionary = facades if facades.has(page) else roofs
			var page_path := String((group.get(page, {}) as Dictionary).get("path", ""))
			assert_true(page_path != "" and ResourceLoader.exists(page_path),
					"%s: page '%s' resolves to nothing on disk" % [key, page])


func test_05_every_cell_carries_the_window_hash_contract_fields() -> void:
	# `building.gdshader` reads `window_cols` / `window_rows` off the mesh's
	# manifest row through `CityView`, and `RenderStateModel.lit_window_count`
	# mirrors the same numbers. A cell missing either grows either no lit
	# windows at all or a division by zero in the emissive count.
	var cells := _cells()
	for key: String in cells:
		var e: Dictionary = cells[key]
		assert_true(e.has("window_cols") and e.has("window_rows"),
				"%s: window grid fields are missing from the manifest row" % key)
		assert_true(e.has("windowless"), "%s: no `windowless` flag" % key)
		var cols := int(e.get("window_cols", 0))
		var rows := int(e.get("window_rows", 0))
		if bool(e.get("windowless", false)):
			assert_eq(cols, 0, "%s: a windowless mesh declares no columns" % key)
			assert_eq(rows, 0, "%s: a windowless mesh declares no rows" % key)
		else:
			assert_true(cols > 0, "%s: window_cols must be positive, got %d" % [key, cols])
			assert_true(rows > 0, "%s: window_rows must be positive, got %d" % [key, rows])


func test_06_every_cell_declares_a_family_the_far_tier_can_index() -> void:
	# `CityView` writes `FAMILY_ORDER.find(family)` into the FAR buffer's `.a`
	# and clamps a miss to 0. A civic tower filed under an unknown family
	# therefore lights with residential window colour at Z2 and nothing says so.
	var cells := _cells()
	for key: String in cells:
		var family := String((cells[key] as Dictionary).get("family", ""))
		assert_true(FAMILY_ORDER.has(family),
				"%s: family '%s' is not in CityView.FAMILY_ORDER — the FAR tier "
				% [key, family] + "would silently draw it as residential")


func test_07_geometry_agrees_with_the_catalog_and_with_the_other_lod() -> void:
	# Three joins in one sweep, because they fail together: the mesh's own AABB,
	# the catalog's footprint, and the sibling LOD.
	var tile_m := float(StarterCityLoader.read_json(SHAPES).get("tile_m", 8.0))
	var catalog := _catalog()
	var cells := _cells()
	for archetype: String in catalog:
		var levels: Array = (catalog[archetype] as Dictionary).get("levels", [])
		for raw: Variant in levels:
			var row: Dictionary = raw
			var level := int(row["level"])
			var foot: Array = row["footprint"]
			var lod0: Dictionary = cells.get("%s:%d:0" % [archetype, level], {})
			var lod1: Dictionary = cells.get("%s:%d:1" % [archetype, level], {})
			if lod0.is_empty() or lod1.is_empty():
				continue  # test 01 already named the missing cell
			var key := "%s:%d" % [archetype, level]
			var mesh_foot: Array = lod0["footprint_tiles"]
			assert_eq(Vector2i(int(mesh_foot[0]), int(mesh_foot[1])),
					Vector2i(int(foot[0]), int(foot[1])),
					"%s: mesh footprint %s vs catalog %s" % [key, mesh_foot, foot])
			var h := float(lod0["height_m"])
			assert_true(h > 0.0, "%s: height_m must be positive" % key)
			var aabb: Array = lod0["aabb"]
			assert_almost_eq(float(aabb[1]), h, 0.001,
					"%s: aabb height disagrees with height_m" % key)
			assert_almost_eq(float(aabb[0]), float(foot[0]) * tile_m, 0.001,
					"%s: aabb x is not the footprint in metres" % key)
			assert_almost_eq(float(aabb[2]), float(foot[1]) * tile_m, 0.001,
					"%s: aabb z is not the footprint in metres" % key)
			# The two LODs are the same building, and the LOD1 is ALLOWED to be
			# shorter: `lod1_volume_keep_frac` drops the roof props that are not
			# the signature, so a chimney or a mast goes with them (the 0.75
			# floor on how much may go is `test_graybox_gen::test_08`'s, not
			# this file's). What it may never do is GROW — a LOD1 taller than
			# the LOD0 it replaces pokes through the skyline at the swap
			# distance, and the only reason nothing has ever seen that is that
			# no generator run has produced one.
			assert_true(float(lod1["height_m"]) <= h + 0.001,
					"%s: LOD1 is TALLER than LOD0 (%.2f vs %.2f m) — it would "
					% [key, float(lod1["height_m"]), h]
					+ "poke through at the swap")
			assert_eq(String(lod1["roof_signature"]), String(lod0["roof_signature"]),
					"%s: LOD1 lost the roof signature" % key)
			assert_eq(String(lod1["silhouette_descriptor"]),
					String(lod0["silhouette_descriptor"]),
					"%s: LOD1 reads as a different silhouette" % key)


func test_07b_the_height_the_far_tier_scales_by_comes_off_lod0() -> void:
	# The reason test 07 may let LOD1 be shorter. `CityView` builds `_far_scale`
	# — the per-instance Y the shared unit box is stretched by at Z2 — inside
	# an `if int(entry["lod"]) == 0:` arm, so the twenty cells whose LOD1 lost a
	# mast do not shrink the far skyline. Move that write out of the arm and the
	# manifest's row ORDER starts deciding how tall the city looks; this is the
	# assertion that stops it.
	var src := _text_of("res://game/render/city_view.gd")
	assert_true(src != "", "city_view.gd is readable")
	var arm := src.find('if int(entry["lod"]) == 0:')
	assert_true(arm >= 0, "city_view.gd no longer has a LOD0 manifest arm")
	var write := src.find("_far_scale[")
	assert_true(write > arm,
			"the far scale table is written outside the LOD0 arm — the FAR tier "
			+ "would take whichever LOD's height_m the manifest lists last")


func test_08_the_shared_far_box_is_present_and_is_the_authored_size() -> void:
	# One row, and the whole Z2 skyline rides on it.
	var far: Dictionary = {}
	for raw: Variant in _meshes():
		if String((raw as Dictionary).get("archetype", "")) == FAR_MESH:
			far = raw
	assert_false(far.is_empty(), "the shared FAR unit box is missing from the manifest")
	if far.is_empty():
		return
	var want := int((StarterCityLoader.read_json(SHAPES).get("far_mesh", {}) as Dictionary)
			.get("tris", 12))
	assert_eq(int(far["tris"]), want, "the FAR box is doc 11 §2.14's %d triangles" % want)
	assert_true(ResourceLoader.exists(String(far["path"])), "the FAR box is on disk")
	var mesh: ArrayMesh = load(String(far["path"]))
	assert_true(mesh != null, "the FAR box loads")


# ------------------------------------------------- 3 — the other rosters

func test_10_every_vehicle_department_has_a_body_a_paint_and_a_livery() -> void:
	# Doc 06's fleet, joined onto doc 11's bodies. A sixth vehicle type in
	# `data/vehicles.json` with no `DEPT_MESH` row falls through
	# `VehicleView._make` to "car" and the city dispatches saloons to fires.
	var types: Dictionary = StarterCityLoader.read_json(VEHICLES).get("types", {})
	assert_true(types.size() >= 5, "doc 06's fleet has at least five types")
	var seen_departments: Dictionary = {}
	for type_id: String in types:
		var department := String((types[type_id] as Dictionary).get("department", ""))
		assert_true(department != "", "%s declares no department" % type_id)
		seen_departments[department] = true
		assert_true(VehicleView.DEPT_MESH.has(department),
				"vehicle type %s (department %s) has no body in VehicleView.DEPT_MESH"
				% [type_id, department])
		assert_true(VehicleView.DEPT_PAINT.has(department),
				"department %s has no paint" % department)
		var body := String(VehicleView.DEPT_MESH.get(department, ""))
		var builder := VehicleMesh.factory(body)
		assert_false(builder.is_empty(), "body '%s' for %s built nothing" % [body, type_id])
		assert_true(builder.tri_count() > 0, "body '%s' has no triangles" % body)
	# Civilian traffic (doc 10 §2.15) is the other half of the same layer.
	for kind: String in VehicleView.CIV_KINDS:
		var civ := VehicleMesh.factory(kind)
		assert_true(civ.tri_count() > 0, "civilian body '%s' has no triangles" % kind)
	# And every body the renderer can name has to be buildable, including the
	# one no department reaches yet.
	for body: String in VehicleView.EMERGENCY_MESHES:
		var m := VehicleMesh.factory(body)
		assert_true(m.tri_count() > 0, "emergency body '%s' has no triangles" % body)


func test_11_the_vehicle_atlas_declares_every_cell_a_body_can_ask_for() -> void:
	# The livery half. `VehicleMesh` bakes UV2 as `cell + face`, so a page that
	# stops declaring one of the four cells puts a car door on the glass cell.
	var tex := _tex()
	var atlas: Dictionary = (tex.get("vehicles", {}) as Dictionary).get("atlas", {})
	assert_false(atlas.is_empty(), "the vehicle atlas is not declared")
	var path := String(atlas.get("path", ""))
	assert_true(ResourceLoader.exists(path), "the vehicle atlas page is missing")
	var cells: Dictionary = tex.get("vehicle_cells", {})
	for cell_name: String in ["paint", "glass", "dark", "livery"]:
		assert_true(cells.has(cell_name), "the atlas declares no '%s' cell" % cell_name)
	assert_eq(Vector2(VehicleMesh.CELL_PAINT), _cell_vec(cells, "paint"),
			"VehicleMesh.CELL_PAINT and the manifest disagree")
	assert_eq(Vector2(VehicleMesh.CELL_GLASS), _cell_vec(cells, "glass"),
			"VehicleMesh.CELL_GLASS and the manifest disagree")
	assert_eq(Vector2(VehicleMesh.CELL_DARK), _cell_vec(cells, "dark"),
			"VehicleMesh.CELL_DARK and the manifest disagree")
	assert_eq(Vector2(VehicleMesh.CELL_LIVERY), _cell_vec(cells, "livery"),
			"VehicleMesh.CELL_LIVERY and the manifest disagree")
	assert_almost_eq(VehicleMesh.UV_INSET, float(tex.get("vehicle_uv_inset", 0.0)),
			0.0001, "the inset the meshes bake and the one the page declares")


func _cell_vec(cells: Dictionary, name: String) -> Vector2:
	var pair: Array = cells.get(name, [0, 0])
	return Vector2(float(pair[0]), float(pair[1]))


func test_12_every_construction_machine_has_a_mesh_inside_its_budget() -> void:
	# Doc 11 §2.16's plant. Five factories, and the yard is not "textured" until
	# every surface code one of them writes has a page behind it.
	var cfg: Dictionary = _render().get("construction_vehicles", {})
	var machines := {
		"excavator": ConstructionRigMesh.excavator(),
		"dump_truck": ConstructionRigMesh.dump_truck(),
		"pile_heap": ConstructionRigMesh.pile_heap(0),
		"pile_stack": ConstructionRigMesh.pile_stack(),
		"barrier_bay": ConstructionRigMesh.barrier_bay(),
	}
	for name: String in machines:
		var rig: ConstructionRigMesh = machines[name]
		assert_false(rig.is_empty(), "construction machine '%s' built nothing" % name)
		assert_true(rig.tri_count() > 0, "'%s' has no triangles" % name)
		var mesh := rig.to_mesh()
		assert_true(mesh != null and mesh.get_surface_count() == 1,
				"'%s' does not resolve to one surface" % name)
		var bounds := rig.bounds()
		assert_true(bounds.size.length() > 0.1, "'%s' has no extent" % name)
	# …and the yard has to be a place, not a set of flat boxes: the layer takes
	# its two surfaces off `PropSurface`, so the pages are the second half of
	# "this machine has an asset". (The per-machine triangle budgets are
	# `test_construction_living`'s; this file asks only whether the thing
	# exists and is dressed.)
	for page: String in ["steel", "stock"]:
		var mat := PropSurface.material(page)
		assert_true(mat != null and mat.albedo_texture != null,
				"the construction layer's '%s' page is missing — the plant "
				% page + "would draw untextured")
	assert_true(int(cfg.get("max_sites", 0)) > 0,
			"the construction layer is capped at zero sites and draws nothing")


func test_13_the_props_layer_has_a_page_for_every_surface_it_names() -> void:
	# `PropSurface` is the one material factory for hoarding, plant, stockpiles
	# and lamp posts. A page group that loses a row leaves the consumer with a
	# flat vertex-coloured fallback and no error anywhere.
	var pages: Dictionary = (_tex().get("props", {}) as Dictionary)
	for page: String in ["hoarding", "steel", "stock"]:
		assert_true(pages.has(page), "prop page '%s' is not declared" % page)
		assert_true(PropSurface.has_page(page), "PropSurface cannot resolve '%s'" % page)
		var mat := PropSurface.material(page)
		assert_true(mat != null, "'%s' yields no material" % page)
		assert_true(mat.albedo_texture != null,
				"'%s' resolves a material with NO TEXTURE — the props layer is bare"
				% page)
	assert_true(PropSurface.tile_m() > 0.0, "the prop page pitch is declared")


func test_14_the_streetlight_has_a_head_and_wears_the_prop_page() -> void:
	# Doc 11 §2.10.1. The pole is the most-instanced prop in the city and the
	# one whose absence reads as "sticks popping out of the ground".
	var cfg: Dictionary = (_render().get("road_surface", {}) as Dictionary).get("lamp", {})
	var mesh := CobraHeadMesh.build(cfg)
	assert_true(mesh != null, "the cobra head built nothing")
	if mesh == null:
		return
	assert_eq(mesh.get_surface_count(), 1, "one surface for every lamp in the city")
	var arrays := mesh.surface_get_arrays(0)
	var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	assert_true(indices.size() >= 3, "the cobra head has no triangles")
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	assert_eq(cols.size(), verts.size(),
			"the pole's baked weathering rides vertex COLOR, one per vertex")
	var head := CobraHeadMesh.head_offset(cfg)
	assert_true(head.y > 0.0, "the luminaire is above grade")
	assert_true(absf(head.x) > 0.0, "the arm reaches out over the carriageway")
	assert_true(PropSurface.has_page("steel"), "the pole has no galvanised page")


func test_15_the_power_distribution_layer_has_a_pad_a_wire_and_a_plume() -> void:
	# Doc 11 §2.10b. Three meshes and three shaders; the layer that closed doc
	# 91 §4's "fully shipped and wholly invisible" gap.
	var view := PowerInfraView.new()
	view.setup(_render())
	assert_true(view.pad_triangle_count() > 0, "the transformer pad has no geometry")
	assert_true(view.wire_triangle_count() > 0, "the service drop has no geometry")
	var mesh: ArrayMesh = view._pad_mesh
	assert_true(mesh != null and mesh.get_surface_count() == 1,
			"the pad does not resolve to one surface")
	if mesh != null:
		var cols: PackedColorArray = mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
		assert_true(cols.size() > 0, "the pad carries no part ids in COLOR.a")
	view.free()


func test_16_every_ground_road_and_water_surface_resolves_a_page() -> void:
	# The four surfaces a player is always looking at. `GroundSurface` falls
	# back to a flat `StandardMaterial3D` when a page is missing, which is a
	# correct degrade and an invisible regression — so the pages are asserted
	# here, not the fallback.
	var grounds: Dictionary = (_tex().get("grounds", {}) as Dictionary)
	for page: String in ["asphalt", "pavement"]:
		assert_true(grounds.has(page), "ground page '%s' is not declared" % page)
		var path := String((grounds[page] as Dictionary).get("path", ""))
		assert_true(ResourceLoader.exists(path), "ground page '%s' is not on disk" % page)
	var road := GroundSurface.road_material()
	assert_true(road is ShaderMaterial,
			"the road surface fell back to the untextured material")
	var water := GroundSurface.water()
	assert_true(water is ShaderMaterial, "the canal fell back to a flat material")
	var block := GroundSurface.block_material(0, true)
	assert_true(block != null, "a developed block has no ground material")
	assert_true(GroundSurface.tile_m() > 0.0, "the ground page pitch is declared")
	assert_true(GroundSurface.district_tone_count() > 0, "no district tones are declared")


func test_17_every_shipped_shader_loads_and_has_an_owner() -> void:
	# A `.gdshader` that nothing references is either dead or a layer that lost
	# its material in a refactor. Both are asset gaps and neither shows up in a
	# screenshot until the frame it matters.
	var dir := DirAccess.open(SHADER_DIR)
	assert_true(dir != null, "the shader directory is readable")
	var on_disk: Array[String] = []
	if dir != null:
		for f: String in dir.get_files():
			if f.ends_with(".gdshader"):
				on_disk.append(f)
	on_disk.sort()
	var expected: Array[String] = []
	expected.assign(SHADERS)
	expected.sort()
	assert_eq(on_disk, expected,
			"the shipped shader set moved — add the new row to SHADERS and to "
			+ "SHADER_OWNER, or say why the removed one is gone")
	for name: String in SHADERS:
		var path := "%s/%s" % [SHADER_DIR, name]
		assert_true(ResourceLoader.exists(path), "%s is missing" % name)
		if not ResourceLoader.exists(path):
			continue
		var shader: Shader = load(path)
		assert_true(shader != null, "%s did not load as a Shader" % name)
		var owner_path := String(SHADER_OWNER.get(name, ""))
		var owner_src := _text_of(owner_path)
		assert_true(owner_src != "", "%s: owner %s is unreadable" % [name, owner_path])
		assert_true(owner_src.contains(name),
				"%s is referenced by nothing — %s no longer names it"
				% [name, owner_path])


func test_18_every_texture_page_is_worn_by_something() -> void:
	# The reverse join. A page that ships and is worn by nobody is dead VRAM in
	# the export, and a page group with no reader is a whole family drawn bare.
	var tex := _tex()
	var total := 0
	for group: String in PAGE_GROUP_READER:
		var pages: Dictionary = tex.get(group, {})
		assert_true(pages.size() > 0, "page group '%s' is empty" % group)
		var reader_path := String(PAGE_GROUP_READER[group])
		var reader := _text_of(reader_path)
		assert_true(reader != "", "the reader for group '%s' is unreadable" % group)
		assert_true(reader.contains(TEX_MANIFEST),
				"%s no longer opens the texture manifest at all" % reader_path)
		assert_true(reader.contains('"%s"' % group),
				"nothing reads the '%s' group — %s does not name it"
				% [group, reader_path])
		for page: String in pages:
			var path := String((pages[page] as Dictionary).get("path", ""))
			assert_true(ResourceLoader.exists(path),
					"%s/%s: %s is not on disk" % [group, page, path])
			assert_true(FileAccess.file_exists(path + ".import"),
					"%s/%s has no .import — it will not reach the export" % [group, page])
			total += 1
	assert_eq(total, 18, "eighteen pages ship; a new one wants a row in this sweep")
	# Every facade and roof page must be CLAIMED by at least one archetype or
	# family, or it is a page nobody wears.
	var claimed: Dictionary = {}
	for table: String in ["archetype_surface", "family_surface"]:
		for owner: String in tex.get(table, {}):
			var surface: Dictionary = (tex[table] as Dictionary)[owner]
			claimed[String(surface.get("facade", ""))] = true
			claimed[String(surface.get("roof", ""))] = true
	for page: String in tex.get("facades", {}):
		assert_true(claimed.has(page), "facade page '%s' is worn by no archetype" % page)
	for page2: String in tex.get("roofs", {}):
		assert_true(claimed.has(page2), "roof page '%s' is worn by no archetype" % page2)


# ----------------------------------------------------------- 4 — the census

func test_19_the_matrix_census_is_what_doc_91_records() -> void:
	# The one assertion in this file that is a NUMBER rather than a rule. Doc 91
	# §16 quotes these totals; a wave that adds an archetype, a rung, a vehicle
	# type or a page has to come here and move them, which is the point — the
	# matrix cannot grow silently, and the audit's headline cannot go stale
	# without a red suite.
	assert_eq(_cells().size(), 132, "building meshes (12 archetypes x rungs x 2 LODs)")
	assert_eq(_meshes().size(), 133, "…plus the one shared FAR box")
	var tex := _tex()
	assert_eq((tex.get("facades", {}) as Dictionary).size(), 8, "facade pages")
	assert_eq((tex.get("roofs", {}) as Dictionary).size(), 4, "roof pages")
	assert_eq((tex.get("grounds", {}) as Dictionary).size(), 2, "ground pages")
	assert_eq((tex.get("props", {}) as Dictionary).size(), 3, "prop pages")
	assert_eq((tex.get("vehicles", {}) as Dictionary).size(), 1, "vehicle atlas")
	# 16 since A91-D-26: `flood.gdshader` is doc 07 §2.4's standing water, which
	# the sim had been integrating and nothing had been drawing. **18 since doc
	# 11 §2.17**: `street_life.gdshader` is the crook, the dog and the goat, and
	# `street_fx.gdshader` is the marker, the label, the poof and the sparkle —
	# four effects on one buffer, which is why there is one shader and not four.
	# **19 since Wave 17** (doc 98 §43 / RR-114): `sky_gradient.gdshader` is the
	# gradient sky the manual pitch axis made visible — the first shader in this
	# list whose owner is the environment rather than a `game/render/` view.
	assert_eq(SHADERS.size(), 19, "shaders")
	assert_eq((StarterCityLoader.read_json(VEHICLES).get("types", {}) as Dictionary).size(),
			5, "doc 06 vehicle types")
	assert_eq(DEFERRED_BODIES.size(), 1,
			"one body ships ahead of its sim door — doc 91 A91-D-20")
