extends SimTest
## The props surface pass: `tools/gen_textures.py`'s `prop_*` pages, the
## `PropSurface` materials built from them, the UVs `ConstructionSiteView` and
## `StreetlightView` bake to carry them, and the per-district ground tones
## `GroundSurface` hands the block planes.
##
## What is actually under test is the thing that rots silently. The pages
## themselves are judged in screenshots; what a test can hold is that a page
## still EXISTS and still reaches the mesh that needs it, that the UVs are in
## METRES (so one steel page fits a 0.22 m crane leg and an 8 m lamp post at the
## same grain), and that a clone with no generated pages still gets a working
## flat material instead of a crash.

const TEX_MANIFEST := "res://game/textures/generated/manifest.json"
const RENDER_DATA := "res://data/render.json"


func _tex() -> Dictionary:
	return StarterCityLoader.read_json(TEX_MANIFEST)


func _render() -> Dictionary:
	return StarterCityLoader.read_json(RENDER_DATA)


func _uvs_of(mesh: Mesh) -> PackedVector2Array:
	if mesh == null or mesh.get_surface_count() == 0:
		return PackedVector2Array()
	return mesh.surface_get_arrays(0)[Mesh.ARRAY_TEX_UV]


# ------------------------------------------------------------------ the pages

func test_01_prop_pages_are_declared_and_load() -> void:
	var pages: Dictionary = _tex().get("props", {})
	for name in ["hoarding", "steel", "stock"]:
		assert_true(pages.has(name), "prop page %s is declared" % name)
		if not pages.has(name):
			continue
		var path := String((pages[name] as Dictionary).get("path", ""))
		assert_true(ResourceLoader.exists(path), "%s missing" % path)
		var res: Texture2D = load(path)
		assert_true(res != null, "%s did not load" % path)
		if res == null:
			continue
		var w := res.get_width()
		assert_eq(w, res.get_height(), "%s is not square" % path)
		assert_eq(w & (w - 1), 0, "%s is not power-of-two" % path)


func test_02_prop_pages_declare_their_metre_pitch() -> void:
	# The whole point of the props set: UVs are baked in METRES against this
	# number, so if it moves without the meshes moving with it the crane grain
	# and the lamp-post grain silently stop matching.
	var tex := _tex()
	assert_true(float(tex.get("prop_tile_m", 0.0)) > 0.0, "prop_tile_m declared")
	assert_almost_eq(PropSurface.tile_m(), float(tex.get("prop_tile_m", 0.0)),
			1e-6, "PropSurface reads the manifest pitch")
	var panel: Array = tex.get("hoarding_panel_m", [])
	assert_eq(panel.size(), 2, "the hoarding panel size is declared")


func test_03_prop_materials_keep_the_vertex_colour_as_the_colour() -> void:
	# Every consumer already baked safety orange / crane yellow / timber brown
	# into vertex COLOR. The pages are near-neutral VALUE and must multiply into
	# it, never replace it — drop this flag and every prop in the city turns grey.
	for name in ["hoarding", "steel", "stock"]:
		var mat := PropSurface.material(name)
		assert_true(mat != null, "%s material built" % name)
		assert_true(mat.vertex_color_use_as_albedo,
				"%s must multiply the vertex colour" % name)
		assert_true(mat.albedo_texture != null, "%s carries its page" % name)
		assert_eq(mat.transparency, BaseMaterial3D.TRANSPARENCY_DISABLED,
				"%s: A is the shine mask, never alpha" % name)


func test_04_an_unknown_page_still_yields_a_working_material() -> void:
	# A clone that has not run the generator: no page, no crash, and the flat
	# vertex-coloured material the props layer shipped with.
	var mat := PropSurface.material("no_such_page")
	assert_true(mat != null, "a missing page is not an error")
	assert_true(mat.albedo_texture == null, "…it simply has no page")
	assert_true(mat.vertex_color_use_as_albedo, "…and still takes the tint")


# ------------------------------------------------------ construction site UVs

func _site_view() -> ConstructionSiteView:
	var view := ConstructionSiteView.new()
	view.setup(_render())
	return view


func test_05_hoarding_panels_map_the_printed_page_end_to_end() -> void:
	# The hoarding page is ONE panel with its hazard band at a fixed height. A
	# tiled projection would slide the band with the run length and a 3.6 m bay
	# and a 4.4 m bay would wear different markings, so the panel mesh maps u,v
	# across itself 0..1 — and v runs 0 at the TOP, matching the page.
	var view := _site_view()
	view.add_site(1, Vector3(64.0, 0.0, 64.0), Vector2i(2, 2), 24.0)
	var panel: MultiMeshInstance3D = view.get_node("Site_1/Hoarding")
	var uvs := _uvs_of(panel.multimesh.mesh)
	assert_true(uvs.size() > 0, "the panel carries UVs")
	var lo := Vector2(9.0, 9.0)
	var hi := Vector2(-9.0, -9.0)
	for uv: Vector2 in uvs:
		lo = Vector2(minf(lo.x, uv.x), minf(lo.y, uv.y))
		hi = Vector2(maxf(hi.x, uv.x), maxf(hi.y, uv.y))
	assert_almost_eq(lo.x, 0.0, 1e-4, "panel u starts at 0")
	assert_almost_eq(hi.x, 1.0, 1e-4, "panel u ends at 1")
	assert_almost_eq(lo.y, 0.0, 1e-4, "panel v starts at 0 (the page's top)")
	assert_almost_eq(hi.y, 1.0, 1e-4, "panel v ends at 1")
	view.free()


func test_06_crane_and_scaffold_uvs_are_in_metres() -> void:
	# A tower crane mast is ~30 m tall and the page repeats every `prop_tile_m`.
	# If the UV were normalised per mesh the AO bands would stretch to one band
	# per mast and the lattice would go flat.
	var view := _site_view()
	view.add_site(2, Vector3(64.0, 0.0, 64.0), Vector2i(2, 2), 40.0)
	assert_true(view.has_crane(2), "a 40 m building gets a tower crane")
	var mast: MeshInstance3D = view.get_node("Site_2/Crane/Mast")
	var uvs := _uvs_of(mast.mesh)
	assert_true(uvs.size() > 0, "the mast carries UVs")
	var span := 0.0
	for uv: Vector2 in uvs:
		span = maxf(span, absf(uv.y))
	# mast_h is at least the building height, so v must cover many repeats.
	assert_true(span > 40.0 / PropSurface.tile_m() * 0.5,
			"mast v spans %f repeats, expected metres-per-tile" % span)
	view.free()


func test_07_every_site_prop_carries_a_uv_and_a_page() -> void:
	var view := _site_view()
	view.add_site(3, Vector3(64.0, 0.0, 64.0), Vector2i(2, 2), 40.0)
	view.set_stage(3, 2)
	for path in ["Site_3/Hoarding", "Site_3/Posts", "Site_3/Crane/Mast",
			"Site_3/Stockpile"]:
		var node: Node = view.get_node_or_null(path)
		assert_true(node != null, "%s exists" % path)
		if node == null:
			continue
		var mesh: Mesh = node.multimesh.mesh if node is MultiMeshInstance3D \
				else (node as MeshInstance3D).mesh
		assert_true(_uvs_of(mesh).size() > 0, "%s carries UVs" % path)
		var mat: Material = mesh.surface_get_material(0)
		assert_true(mat is StandardMaterial3D, "%s has a prop material" % path)
		assert_true((mat as StandardMaterial3D).albedo_texture != null,
				"%s samples a prop page" % path)
	view.free()


# ------------------------------------------------------------- the lamp post

func _lamp_view() -> StreetlightView:
	var render := _render()
	var model := RenderStateModel.new(render)
	var view := StreetlightView.new()
	view.setup(model, render, [{"id": 1, "block_id": "B", "pos": Vector3(40.0, 0.0, 40.0)}])
	return view


func test_08_the_pole_carries_baked_base_weathering() -> void:
	# The page is TILED, so weathering authored into it would repeat every
	# `prop_tile_m` up the shaft and read as a barber's pole. The grime ramp is
	# vertex colour instead — dark at grade, clean above `POLE_GRIME_M`.
	var view := _lamp_view()
	var pole: MultiMeshInstance3D = null
	for child in view.get_children():
		var node := child as MultiMeshInstance3D
		if node != null and node.multimesh.mesh is ArrayMesh \
				and node.multimesh.mesh.get_surface_count() > 0 \
				and _uvs_of(node.multimesh.mesh).size() > 0:
			pole = node
	assert_true(pole != null, "the chunk built a pole MultiMesh")
	if pole == null:
		view.free()
		return
	var arrays := (pole.multimesh.mesh as ArrayMesh).surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var cols: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var lowest := 9.0
	var highest := 0.0
	for i in verts.size():
		if verts[i].y < 0.01:
			lowest = minf(lowest, cols[i].r)
		if verts[i].y > StreetlightView.POLE_HEIGHT - 0.01:
			highest = maxf(highest, cols[i].r)
	assert_true(lowest < highest,
			"grade %f must be dirtier than the head %f" % [lowest, highest])
	assert_almost_eq(highest, 1.0, 1e-3, "the shaft is clean above the grime band")
	view.free()


func test_09_the_pole_stands_on_its_origin_and_wears_the_steel_page() -> void:
	var view := _lamp_view()
	var pole: MultiMeshInstance3D = null
	for child in view.get_children():
		var node := child as MultiMeshInstance3D
		if node != null and node.multimesh.mesh is ArrayMesh \
				and node.multimesh.mesh.get_surface_count() > 0 \
				and _uvs_of(node.multimesh.mesh).size() > 0:
			pole = node
	assert_true(pole != null, "the chunk built a pole MultiMesh")
	if pole == null:
		view.free()
		return
	var mesh := pole.multimesh.mesh as ArrayMesh
	var verts: PackedVector3Array = mesh.surface_get_arrays(0)[Mesh.ARRAY_VERTEX]
	var lowest := 9.0
	var top := 0.0
	for p: Vector3 in verts:
		lowest = minf(lowest, p.y)
		top = maxf(top, p.y)
	assert_true(verts.size() > 0,
			"the pole mesh is not empty — the builder's lambdas write through")
	assert_eq(mesh.surface_get_arrays(0)[Mesh.ARRAY_INDEX].size() / 3, 34,
			"the pole is 34 triangles: 12 shaft quads, a 4-quad collar and a cap")
	assert_almost_eq(lowest, 0.0, 1e-4,
			"the pole rests on y=0 so the grime lands at the pavement")
	assert_almost_eq(top, StreetlightView.POLE_HEIGHT, 1e-4, "…and reaches the lamp")
	# The instance transform must therefore be the lamp base itself, not a
	# half-height offset (which is what a centred BoxMesh needed).
	var xform := pole.multimesh.get_instance_transform(0)
	assert_almost_eq(xform.origin.y, 0.0, 1e-4, "the instance sits at grade")
	var mat := mesh.surface_get_material(0) as StandardMaterial3D
	assert_true(mat != null and mat.albedo_texture != null,
			"the pole samples the galvanised page")
	view.free()


func test_10_the_lamp_billboard_system_is_untouched() -> void:
	# The pole is the ONLY thing the surface pass was allowed to change here:
	# the billboard, the ground pool and the wet smear are tuned and share
	# `lamp.gdshader` / `light_pool.gdshader`.
	var view := _lamp_view()
	var shaders: Dictionary = {}
	for child in view.get_children():
		var node := child as MultiMeshInstance3D
		if node == null:
			continue
		var mat := node.material_override as ShaderMaterial
		if mat != null and mat.shader != null:
			shaders[mat.shader.resource_path] = true
	assert_true(shaders.has("res://game/shaders/lamp.gdshader"),
			"the lamp billboard still runs lamp.gdshader")
	assert_true(shaders.has("res://game/shaders/light_pool.gdshader"),
			"the ground pool still runs light_pool.gdshader")
	view.free()


# --------------------------------------------------------- district ground

func test_11_district_tones_are_declared_and_distinct() -> void:
	var ground: Dictionary = _render().get("ground", {})
	var tones: Array = ground.get("district_tones", [])
	assert_true(tones.size() >= 4, "a tone per starter district, got %d" % tones.size())
	var seen: Dictionary = {}
	for hex in tones:
		assert_true(Color.html_is_valid(String(hex)), "%s is a colour" % str(hex))
		assert_false(seen.has(String(hex)), "%s is used twice" % str(hex))
		seen[String(hex)] = true
	assert_eq(GroundSurface.district_tone_count(), tones.size(),
			"GroundSurface reads the same table")


func test_12_district_tones_are_a_trim_not_a_repaint() -> void:
	# Constitution §11: colour is never the only carrier, and a district tone is
	# a HINT — a neighbourhood you can pick out of a skyline, not four
	# differently-painted cities. Every tone has to stay inside a narrow band of
	# the developed tint or the ground stops reading as one city.
	var ground: Dictionary = _render().get("ground", {})
	var base := Color(String(ground.get("developed_tint", "#858785")))
	var base_luma := base.r * 0.2126 + base.g * 0.7152 + base.b * 0.0722
	for hex in ground.get("district_tones", []):
		var tone := Color(String(hex))
		var luma := tone.r * 0.2126 + tone.g * 0.7152 + tone.b * 0.0722
		assert_true(absf(luma - base_luma) < 0.10,
				"%s is %.3f off the developed tint's %.3f — that is a repaint"
				% [str(hex), luma, base_luma])


func test_13_a_block_with_no_district_reads_as_undeveloped() -> void:
	# -1 is the t0 case: every unbought block. It must take the scrub tint, which
	# is what makes the owned core read as a built patch inside open land.
	var ground: Dictionary = _render().get("ground", {})
	var scrub := Color(String(ground.get("undeveloped_tint", "#66805C")))
	var mat := GroundSurface.block_material(-1, false) as ShaderMaterial
	assert_true(mat != null, "the ground material is the shader one")
	if mat == null:
		return
	var tint: Color = mat.get_shader_parameter("tint")
	assert_true(tint.is_equal_approx(scrub), "no district -> the undeveloped tint")


func test_14_block_materials_are_shared_per_tone() -> void:
	# main.gd builds 49 of these. Handing each plane its own ShaderMaterial would
	# cost 49 pipeline states for four looks.
	var a := GroundSurface.block_material(1, true)
	var b := GroundSurface.block_material(1, true)
	var c := GroundSurface.block_material(2, true)
	assert_true(a == b, "the same district shares one material")
	assert_true(a != c, "a different district does not")
