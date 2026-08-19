extends SimTest
## Procedural building-surface set (`tools/gen_textures.py` +
## `game/shaders/building.gdshader`), doc 11 §2.6 and §2.14.
##
## The load-bearing claim under test is the *alignment* one: a texture bay and
## an emissive cell are the same rectangle, so the glow lands inside the drawn
## pane. Everything else here guards the things that silently rot — a new
## archetype with no surface, an `.import` that drifts off VRAM/mipmaps, or an
## edit to the shader that breaks the §2.6 window-hash contract that
## `RenderStateModel.lit_window_count` mirrors.

const TEX_MANIFEST := "res://game/textures/generated/manifest.json"
const MESH_MANIFEST := "res://game/meshes/generated/manifest.json"
const SHADER := "res://game/shaders/building.gdshader"


func _tex() -> Dictionary:
	return StarterCityLoader.read_json(TEX_MANIFEST)


func _shader_source() -> String:
	var f := FileAccess.open(SHADER, FileAccess.READ)
	if f == null:
		return ""
	return f.get_as_text()


# ------------------------------------------------------------------ coverage

func test_01_every_archetype_resolves_to_a_surface() -> void:
	var tex := _tex()
	var facades: Dictionary = tex.get("facades", {})
	var roofs: Dictionary = tex.get("roofs", {})
	assert_true(facades.size() >= 4, "at least one page per family group")
	var by_arch: Dictionary = tex.get("archetype_surface", {})
	var by_family: Dictionary = tex.get("family_surface", {})
	var meshes: Dictionary = StarterCityLoader.read_json(MESH_MANIFEST)
	var seen := {}
	for entry in meshes.get("meshes", []):
		var archetype := String(entry["archetype"])
		var family := String(entry.get("family", ""))
		if archetype == "far_unit_box":
			continue  # FAR tier has its own shader (§2.6), no facade page
		if seen.has(archetype):
			continue
		seen[archetype] = true
		var surface: Dictionary = by_arch.get(archetype, by_family.get(family, {}))
		assert_false(surface.is_empty(), "%s has no surface mapping" % archetype)
		assert_true(facades.has(String(surface.get("facade", ""))),
				"%s facade page missing" % archetype)
		assert_true(roofs.has(String(surface.get("roof", ""))),
				"%s roof page missing" % archetype)
	assert_true(seen.size() >= 12, "saw every shipped archetype, got %d" % seen.size())


func test_02_every_page_loads_as_a_texture() -> void:
	var tex := _tex()
	for group in ["facades", "roofs", "grounds", "props", "vehicles"]:
		var pages: Dictionary = tex.get(group, {})
		assert_true(pages.size() > 0, "%s group is empty" % group)
		for name in pages:
			var path := String((pages[name] as Dictionary).get("path", ""))
			assert_true(ResourceLoader.exists(path), "%s missing" % path)
			var res: Texture2D = load(path)
			assert_true(res != null, "%s did not load" % path)
			if res == null:
				continue
			var w := res.get_width()
			var h := res.get_height()
			assert_eq(w, h, "%s is not square" % path)
			assert_eq(w & (w - 1), 0, "%s is not power-of-two (%d)" % [path, w])
			assert_true(w >= 256 and w <= 1024,
					"%s is %d px, outside the 256–1024 budget" % [path, w])


func test_03_facade_pages_are_two_bays_square() -> void:
	# The shader divides the bay coordinate by 2 to reach page space; if a page
	# ever stops being exactly 2x2 bays the windows slide off their cells.
	var tex := _tex()
	var bay_px := int(tex.get("bay_px", 0))
	var page_px := int(tex.get("page_px", 0))
	assert_true(bay_px > 0, "bay_px declared")
	assert_eq(page_px, bay_px * 2, "facade page is 2 bays square")
	for name in tex.get("facades", {}):
		var path := String((tex["facades"][name] as Dictionary).get("path", ""))
		var res: Texture2D = load(path)
		if res != null:
			assert_eq(res.get_width(), page_px, "%s is not the declared page size" % path)


# --------------------------------------------------------- import settings

func test_04_pages_import_vram_compressed_and_mipmapped() -> void:
	# doc 13 / project.godot: textures/vram_compression/import_etc2_astc is on,
	# and a 256 px bay is roughly one pixel at Z2 — without mipmaps the whole
	# skyline crawls.
	var tex := _tex()
	for group in ["facades", "roofs", "grounds", "props", "vehicles"]:
		for name in tex.get(group, {}):
			var path := String((tex[group][name] as Dictionary).get("path", ""))
			var f := FileAccess.open(path + ".import", FileAccess.READ)
			assert_true(f != null, "%s.import missing" % path)
			if f == null:
				continue
			var text := f.get_as_text()
			assert_true(text.contains("compress/mode=2"),
					"%s is not VRAM compressed" % path)
			assert_true(text.contains("mipmaps/generate=true"),
					"%s has no mipmaps" % path)
			assert_true(text.contains("detect_3d/compress_to=0"),
					"%s would be re-decided on first 3D use" % path)


# ------------------------------------------------------------- the alignment

func _tex_bay_index(uv2: Vector2, cols: int, rows: int, variant: int) -> Vector2i:
	# Mirrors the shader exactly:
	#   bay    = UV2 * vec2(cols, rows)
	#   tex_uv = vec2(bay.x + mod(variant,2), 2.0 - bay.y) * 0.5
	# One page bay is 0.5 in page space, so the bay index is floor(tex_uv * 2).
	var bay := Vector2(uv2.x * cols, uv2.y * rows)
	var tex_uv := Vector2(bay.x + fposmod(float(variant), 2.0), 2.0 - bay.y) * 0.5
	return Vector2i(int(floor(tex_uv.x * 2.0)), int(floor(tex_uv.y * 2.0)))


func test_05_one_texture_bay_covers_exactly_one_emissive_cell() -> void:
	# The whole point of the layout: sample anywhere inside an emissive cell and
	# you are inside one and the same texture bay. If this drifts, lit windows
	# stop landing on drawn panes.
	var cases := [[5, 34, 0], [5, 48, 7], [2, 1, 15], [4, 3, 3], [9, 4, 8]]
	for case in cases:
		var cols := int(case[0])
		var rows := int(case[1])
		var variant := int(case[2])
		for cy in mini(rows, 12):
			for cx in cols:
				var first := Vector2i(-999, -999)
				for sy in 5:
					for sx in 5:
						# strictly inside cell (cx, cy)
						var uv2 := Vector2(
								(cx + 0.1 + 0.2 * sx) / float(cols),
								(cy + 0.1 + 0.2 * sy) / float(rows))
						var idx := _tex_bay_index(uv2, cols, rows, variant)
						if first.x == -999:
							first = idx
						assert_eq(idx, first,
								"cell (%d,%d) of %dx%d spans two texture bays"
								% [cx, cy, cols, rows])


func test_06_ground_floor_maps_to_the_page_bottom_half() -> void:
	# The storefront page puts shopfront glazing on its lower row; that only
	# works because bay row 0 samples v in the bottom half of the page.
	var cols := 5
	var rows := 4
	for sx in 5:
		var uv2 := Vector2((0.1 + 0.2 * sx) / float(cols), 0.5 / float(rows))
		var bay := Vector2(uv2.x * cols, uv2.y * rows)
		var v := (2.0 - bay.y) * 0.5
		assert_true(v > 0.5 and v <= 1.0,
				"bay row 0 sampled v = %f, expected the bottom half" % v)
	var uv_row1 := Vector2(0.5, 1.5 / float(rows))
	var v1 := (2.0 - uv_row1.y * rows) * 0.5
	assert_true(v1 > 0.0 and v1 <= 0.5,
			"bay row 1 sampled v = %f, expected the top half" % v1)


# ------------------------------------------------- the §2.6 shader contract

func test_07_shader_keeps_the_window_hash_contract() -> void:
	# Two agents edit this file (textures, construction stages). These four
	# lines are what RenderStateModel.lit_window_count mirrors — §2.6 locks
	# them, so any edit that loses one has to fail here rather than in a
	# playtest three weeks later.
	var src := _shader_source()
	assert_true(src != "", "shader source readable")
	for needle in [
			"vec2 cell = floor(v_uv2 * vec2(window_cols, window_rows));",
			"hash21(cell + vec2(variant * 37.0, variant * 11.0))",
			"float lit = step(1.0 - e, h);",
			"float gate = mix(day_gate, 1.0, sc_night);",
			"float e = v_custom.r * gate;"]:
		assert_true(src.contains(needle), "shader lost: %s" % needle)


func test_08_instance_custom_is_flat_interpolated() -> void:
	# Interpolating INSTANCE_CUSTOM walks `variant` off the integers, and
	# `variant * 37.0` inside hash21 turns that into a different hash per pixel
	# — every lit window dithers into salt-and-pepper. `flat` is the fix and it
	# must not be dropped.
	var src := _shader_source()
	assert_true(src.contains("varying flat vec4 v_custom;"),
			"v_custom must be flat or the per-window hash dithers per pixel")


func test_08b_roof_props_sample_the_roof_page_not_the_facade() -> void:
	# The texture pass's open question 3, closed. A roof prop's SIDE faces have
	# no normal to distinguish them from a wall, so they fell through to the
	# façade projection: a rooftop chiller wore brick with a sash window sliced
	# across it and a house's gable end grew half a window. `gen_graybox.gd`
	# marks them UV2 = (-1,-2) and this is the line that reads it.
	var src := _shader_source()
	assert_true(src.contains("float prop_side = (1.0 - has_uv2) * step(v_uv2.y, -1.5)"),
			"the shader lost the roof-prop surface flag")
	assert_true(src.contains("float use_roof = max(is_roof, prop_side);"),
			"a flagged side face has to take the roof page")
	# And it must cost no extra fetch: one façade sample, one roof sample, the
	# roof one re-projected for a vertical face. A third sampler would have made
	# the whole city pay to dress a handful of rooftop boxes.
	assert_eq(src.count("texture(facade_tex"), 1, "exactly one façade fetch")
	assert_eq(src.count("texture(roof_tex"), 1, "exactly one roof fetch")


func test_09_texture_pass_degrades_to_the_grayboxed_look() -> void:
	# A clone without the generated pages still has to boot: CityView sets
	# tex_mix = 0 and every textured term collapses to what shipped before.
	var src := _shader_source()
	assert_true(src.contains("uniform float tex_mix"), "tex_mix uniform present")
	assert_true(src.contains("mix(base_albedo, surf.rgb, tex_mix)"),
			"albedo falls back to base_albedo at tex_mix = 0")
	assert_true(src.contains("mix(1.0, shine"),
			"emissive pane mask falls back to 1.0 at tex_mix = 0")


func test_10_generator_manifest_is_self_consistent() -> void:
	var tex := _tex()
	assert_eq(String(tex.get("generator", "")), "tools/gen_textures.py")
	assert_true(float(tex.get("roof_tile_m", 0.0)) > 0.0, "roof tile pitch declared")
	var bay: Array = tex.get("bay_m", [])
	assert_eq(bay.size(), 2, "bay_m is a 2-vector")
	assert_true(float(bay[0]) > 0.0 and float(bay[1]) > 0.0, "bay_m positive")
	# The two pitches the non-building pages are baked against. Both are read by
	# code (PropSurface, VehicleMesh), so a silent edit here would desynchronise
	# the meshes from their pages with nothing else complaining.
	assert_true(float(tex.get("prop_tile_m", 0.0)) > 0.0, "prop tile pitch declared")
	assert_true(float(tex.get("vehicle_uv_inset", 0.0)) > 0.0,
			"the vehicle atlas declares its cell inset")
	var cells: Dictionary = tex.get("vehicle_cells", {})
	for cell_name in ["paint", "glass", "dark", "livery"]:
		assert_true(cells.has(cell_name), "the atlas declares its %s cell" % cell_name)
	# Every page's committed bytes match the hash the generator recorded, which
	# is what makes `python3 tools/gen_textures.py --check` meaningful in CI.
	for group in ["facades", "roofs", "grounds", "props", "vehicles"]:
		for name in tex.get(group, {}):
			var page: Dictionary = tex[group][name]
			var path := String(page.get("path", ""))
			var want := String(page.get("sha256", ""))
			assert_eq(want.length(), 64, "%s has no recorded hash" % path)
			var bytes := FileAccess.get_file_as_bytes(path)
			assert_true(bytes.size() > 0, "%s unreadable" % path)
			var ctx := HashingContext.new()
			ctx.start(HashingContext.HASH_SHA256)
			ctx.update(bytes)
			assert_eq(ctx.finish().hex_encode(), want,
					"%s does not match its generator hash" % path)
