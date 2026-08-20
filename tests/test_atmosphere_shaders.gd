extends SimTest
## The shader-side half of doc 11 §2.9 / doc 12 §2.5, guarded the only way a
## headless suite can guard a shader: by asserting the source still says what
## the render depends on.
##
## These are not style checks. Each one is a bug that shipped or nearly did:
## additive streetlight passes drawing fog-grey squares along every road at
## noon; an overlay tint that was not skipped at mode 0 and so moved the
## §2.6 window-hash output; a ground material that could not read a shader
## global at all because it was a StandardMaterial3D.

const LAMP := "res://game/shaders/lamp.gdshader"
const POOL := "res://game/shaders/light_pool.gdshader"
const BUILDING := "res://game/shaders/building.gdshader"
const GROUND := "res://game/shaders/ground.gdshader"
const WATER_SHADER := "res://game/shaders/water.gdshader"


func _src(path: String) -> String:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var text := f.get_as_text()
	f.close()
	return text


# ------------------------------------------------- the daylight streetlights

func test_additive_streetlight_passes_disable_fog() -> void:
	# Godot applies depth fog to transparent materials as mix(color, fog, a).
	# On an ADDITIVE pass that ADDS the fog colour, so a lamp quad contributing
	# nothing still painted a flat fog-grey square. Every additive pass that
	# lives in the world must opt out.
	for path in [LAMP, POOL]:
		var src := _src(path)
		assert_true(src != "", "%s readable" % path)
		assert_true(src.contains("blend_add"), "%s is additive" % path)
		assert_true(src.contains("fog_disabled"),
				"%s must opt out of fog or it draws grey in daylight" % path)


func test_streetlights_have_a_hard_day_gate() -> void:
	# Not just "dim in daylight" — GONE. The gate collapses the quad in the
	# vertex stage so no fragment is shaded at all for the ~14 lit hours of
	# every game day.
	for path in [LAMP, POOL]:
		var src := _src(path)
		assert_true(src.contains("smoothstep(night_lo, night_hi, sc_night)"),
				"%s ramps on sc_night" % path)
		assert_true(src.contains("step(0.002, v_gate)"),
				"%s collapses its geometry when the gate is closed" % path)


func test_the_smear_reuses_the_lamp_buffer() -> void:
	# doc 11 §2.9 #2: the wet-smear buffer IS the lamp buffer. One shader, one
	# uniform apart — a second copy would drift.
	var src := _src(LAMP)
	assert_true(src.contains("uniform float smear_mode"), "smear is a mode, not a file")
	assert_true(src.contains("sc_wetness"), "it is gated on wetness")


# ------------------------------------------------------ the overlay contract

func test_overlay_is_one_uniform_branch_and_mode_zero_is_untouched() -> void:
	# The §2.6 lit-window mirror (`RenderStateModel.lit_window_count`) is only
	# valid because the overlay path cannot run at mode 0. A per-fragment blend
	# with a zero factor would NOT be good enough: it has to be skipped.
	var src := _src(BUILDING)
	assert_true(src.contains("global uniform int sc_overlay_mode;"),
			"the overlay mode is the project global doc 12 writes")
	assert_true(src.contains("if (sc_overlay_mode > 0) {"),
			"a single uniform branch guards the whole overlay pass")
	var guard := src.find("if (sc_overlay_mode > 0) {")
	assert_true(src.find("float lit = step(1.0 - e, h);") < guard,
			"the window-hash contract is computed BEFORE the overlay pass and "
			+ "is never inside it")


func test_overlay_desaturates_the_world_in_every_mode() -> void:
	# POLICE and FIRE have no data behind them yet, and TRAFFIC's data is on the
	# ROADS, not on the buildings (doc 12 §4.4). All three still have to LOOK
	# like an overlay here, or the player reads the toggle as broken.
	var src := _src(BUILDING)
	var guard := src.find("if (sc_overlay_mode > 0) {")
	var per_building := src.find("if (sc_overlay_mode == OVERLAY_MODE_POWER")
	assert_true(guard >= 0 and per_building > guard,
			"the per-building overlays are nested inside the guard")
	var shared := src.substr(guard, per_building - guard)
	assert_true(shared.contains("overlay_desaturate"),
			"the de-emphasis is outside the per-building branch")
	assert_true(shared.contains("overlay_emission_mult"),
			"and so is the emissive pull-down")
	assert_true(_src(GROUND).contains("sc_overlay_mode"),
			"the ground greys back too, or only the buildings look overlaid")


func test_every_per_building_overlay_shares_one_state_decoder() -> void:
	# doc 12 §2.5 modes 1–4 differ ONLY in how the 0..3 state was derived: POWER
	# reads the emissive ladder on top of the packed bits, and WATER, POLICE and
	# FIRE read the bits `RenderStateModel.set_overlay_channel` mapped their own
	# system's reading into. One `overlay_paint()` decodes all four, so they
	# cannot drift visually. TRAFFIC (5) is per-EDGE and is not in this branch.
	var src := _src(BUILDING)
	assert_true(src.contains("vec4 overlay_paint(float state, out float emit_amt)"),
			"there is exactly one state → hue/blend/emission decoder")
	assert_true(src.contains("const int OVERLAY_MODE_POWER = 1;"))
	assert_true(src.contains("const int OVERLAY_MODE_WATER = 2;"))
	assert_true(src.contains("const int OVERLAY_MODE_FIRE = 4;"),
			"the per-building branch stops at FIRE, leaving TRAFFIC to the roads")
	# The power-only correction stays inside its own branch: no other mode may
	# have its state raised by a building that happens to be dark.
	var per_building := src.find("if (sc_overlay_mode >= OVERLAY_MODE_POWER")
	var power_only := src.find("if (sc_overlay_mode == OVERLAY_MODE_POWER) {")
	assert_true(per_building >= 0, "the shared branch is a RANGE over modes 1..4")
	assert_true(power_only > per_building,
			"the emissive-ladder read is nested one level deeper than the shared paint")
	assert_true(src.find("float emit_amt;") > power_only,
			"and the shared paint runs after it, on whichever state won")


func test_overlay_carries_motion_as_well_as_hue() -> void:
	# doc 12 §2.5 / constitution: colour is never load-bearing on its own.
	var src := _src(BUILDING)
	assert_true(src.contains("overlay_critical_hz"), "CRITICAL pulses")
	assert_true(src.contains("overlay_offline_hz"), "OFFLINE breathes, slower")


# ------------------------------------------------------------- the wet world

func test_wetness_is_identity_when_dry() -> void:
	# Every wetness term is written as mix(dry, wet, sc_wetness), which is
	# EXACTLY `dry` at 0. That is what keeps the dry frame bit-identical to the
	# frame that shipped before weather existed.
	for path in [BUILDING, GROUND]:
		var src := _src(path)
		assert_true(src.contains("global uniform float sc_wetness;"),
				"%s reads the wetness global" % path)
		assert_true(src.contains("mix(1.0, wet_albedo_mult, sc_wetness)"),
				"%s darkens by an identity-at-zero mix" % path)


func test_ground_material_can_read_a_global_at_all() -> void:
	# The whole reason GroundSurface stopped handing out StandardMaterial3D.
	var mat := GroundSurface.material("asphalt", Vector2(8.0, 8.0), Color(0.34, 0.34, 0.38), 0.85)
	assert_true(mat is ShaderMaterial, "ground is a ShaderMaterial now")
	var shader_mat := mat as ShaderMaterial
	assert_eq(float(shader_mat.get_shader_parameter("dry_roughness")), 0.85,
			"the caller's roughness is the DRY end of the §2.9 ramp")
	var wet := GroundSurface.wet_constants()
	assert_almost_eq(float(shader_mat.get_shader_parameter("wet_albedo_mult")),
			float(wet["albedo_mult"]), 1e-6, "wet albedo comes from data/render.json")
	assert_almost_eq(float(shader_mat.get_shader_parameter("wet_roughness")),
			float(wet["roughness_wet"]), 1e-6)


func test_ground_tiles_at_the_authored_metre_pitch() -> void:
	# A road strip and a 128 m block face must share one texture scale.
	var tile := GroundSurface.tile_m()
	assert_true(tile > 0.0, "tile pitch declared")
	var block := GroundSurface.material("pavement", Vector2(128.0, 128.0)) as ShaderMaterial
	var scale: Vector2 = block.get_shader_parameter("uv_scale")
	assert_almost_eq(scale.x, 128.0 / tile, 1e-4, "128 m spans 128/tile repeats")
	assert_almost_eq(scale.y, 128.0 / tile, 1e-4)


func test_a_clone_without_the_generated_pages_still_boots() -> void:
	# Same contract the texture pass has always had: no page → flat tint.
	var mat := GroundSurface.material("no_such_page", Vector2(8.0, 8.0),
			Color(0.5, 0.5, 0.5)) as ShaderMaterial
	assert_true(mat != null, "still a material")
	assert_almost_eq(float(mat.get_shader_parameter("has_page")), 0.0,
			1e-9, "the shader falls back to the tint")


# ---------------------------------------------------------- the night floor
#
# Report NIGHT-1. The 03:19 playtest shot on the Fold 6 was OFF pixels between
# the streetlights: the street grid, every unlit façade and the canal all
# resolved to 0. These guard the SURFACE half of the fix — the ambient/moon
# half is in test_day_night.gd — and, just as importantly, they guard the
# constraint: the floor is moonlight and citywide skyglow, so it may not grow
# strong enough to erase the blackout ceremony the game is built on.


## Default value of a `uniform float NAME = X;` line, as authored in the shader.
func _uniform_default(src: String, name: String) -> float:
	for line in src.split("\n"):
		var text := String(line).strip_edges()
		if text.begins_with("uniform float %s " % name) and text.contains("="):
			return float(text.split("=")[1].replace(";", "").strip_edges())
	return -1.0


func test_the_ground_carries_a_night_floor_with_two_terms() -> void:
	var src := _src(GROUND)
	assert_true(src.contains("global uniform float sc_night;"),
			"the ground reads the night ramp — before this pass it did not, "
			+ "which is why a road could not know it was midnight")
	# A lift on ALBEDO alone cannot rescue an unlit surface: albedo is a
	# reflectance, and 0.34 × nothing is still nothing. The EMISSION term is
	# the one that survives ambient going to zero, and it is not optional.
	assert_true(src.contains("night_albedo_lift"),
			"term 1: more of what light there is bounces back")
	assert_true(src.contains("EMISSION = night_color * (night_glow * sc_night"),
			"term 2: the skyglow floor, which does not depend on ambient at all")
	assert_true(src.contains("night_glow_wet_mult"),
			"a wet carriageway mirrors the skyglow away from the camera, so the "
			+ "floor comes down as the §2.9 lamp smear takes over")


func test_the_road_gets_a_bigger_night_floor_than_the_ground_it_crosses() -> void:
	# The point of the pass is the GRID, not the brightness. Lifting both
	# surfaces equally would brighten the frame without drawing the street
	# network the player navigates by.
	var road := GroundSurface.night_floor(true)
	var terrain := GroundSurface.night_floor(false)
	assert_true(float(road["albedo_lift"]) > float(terrain["albedo_lift"]),
			"the carriageway lifts harder than the block interior")
	assert_true(float(road["glow"]) > float(terrain["glow"]),
			"…and carries more skyglow with it")
	assert_true(float(terrain["glow"]) > 0.0,
			"but the block ground still has a floor, or the city reads as lit "
			+ "streets around 128 m holes")
	var tint: Color = road["color"]
	assert_true(tint.b > tint.r,
			"the floor is spent in a COOL tint: a warm lift on asphalt reads as "
			+ "daylight, and the frame stops being night")


func test_the_road_row_follows_the_road_page_not_the_district_that_borrows_it() -> void:
	# data/render.json's `district_pages` puts one district's GROUND on the
	# asphalt page. Keying the night floor on the page name alone would light a
	# whole 128 m block like a carriageway, so `block_material` forces the
	# terrain row and only real road strips take the road one.
	var road := GroundSurface.road_material(Vector2(8.0, 8.0)) as ShaderMaterial
	var expected := GroundSurface.night_floor(true)
	assert_almost_eq(float(road.get_shader_parameter("night_glow")),
			float(expected["glow"]), 1e-6, "a road strip takes the road row")
	var ground: Dictionary = StarterCityLoader.read_json(
			"res://data/render.json").get("ground", {})
	var pages: Array = ground.get("district_pages", [])
	var asphalt_district := pages.find(String(ground.get("road_page", "asphalt")))
	if asphalt_district >= 0:
		var block := GroundSurface.block_material(asphalt_district, true) as ShaderMaterial
		assert_almost_eq(float(block.get_shader_parameter("night_glow")),
				float(GroundSurface.night_floor(false)["glow"]), 1e-6,
				"a district that happens to be paved in asphalt is still GROUND")


func test_the_night_floor_is_identity_by_day() -> void:
	# sc_night is 0 at noon and every night term is written as a product with
	# it, so the day frame the project already shipped is untouched — the same
	# identity-at-zero discipline the wetness terms above carry.
	for path in [GROUND, WATER_SHADER]:
		var src := _src(path)
		assert_true(src.contains("night_glow * sc_night"),
				"%s's floor is a product with sc_night, so day is unchanged" % path)


func test_the_canal_stops_being_a_hole_at_night() -> void:
	var src := _src(WATER_SHADER)
	assert_true(src.contains("global uniform vec3 sc_fog_tint;"),
			"at night the fresnel term aims at the SAMPLED sky, not at the "
			+ "authored daytime blue — that is what makes water read as a mirror")
	assert_true(src.contains("night_glow_color * (night_glow * sc_night)"),
			"plus the same skyglow floor the ground carries")
	var water: Dictionary = StarterCityLoader.read_json(
			"res://data/render.json").get("water_surface", {})
	assert_true(float(water.get("night_mult", 0.0)) >= 0.45,
			"0.34 on a #0F2937 body put the canal at (0, 0, 11) on the device")


func test_the_lamp_pool_still_dies_with_its_block() -> void:
	# THE CONSTRAINT. The ground's night floor is deliberately NOT
	# blackout-aware — moonlight does not go out with a substation — so the
	# contrast the ceremony needs comes from the lights that DO. The pool is the
	# widest of them, and every fragment it draws is gated on the model's
	# per-lamp ramp.
	var src := _src(POOL)
	assert_true(src.contains("v_lit = INSTANCE_CUSTOM.r;"),
			"the pool rides the RenderStateModel's per-lamp ramp")
	assert_true(src.contains("* v_gate"),
			"and multiplies by it, so a dark block loses its whole street ribbon")
	assert_true(src.contains("uniform float pool_scale"),
			"the disc is widened in the vertex stage — no rebuilt mesh, no new AABB")
	# Wide enough to cover a carriageway, capped short of turning the Z2
	# skyline into bokeh (a pool is ~19 px of soft disc per metre of radius up
	# there). The read between the poles is the ground's own floor, not this.
	var scale := _uniform_default(src, "pool_scale")
	assert_true(scale > 1.0, "wider than the 6 m disc that read as dots (%f)" % [scale])
	assert_true(scale <= 2.0, "and not so wide the skyline is circles (%f)" % [scale])
