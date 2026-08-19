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
	# Modes 2–5 have no data behind them yet (doc 12 §4.4). They still have to
	# LOOK like an overlay, or the player reads the toggle as broken.
	var src := _src(BUILDING)
	var guard := src.find("if (sc_overlay_mode > 0) {")
	var power := src.find("if (sc_overlay_mode == 1) {")
	assert_true(guard >= 0 and power > guard, "POWER is nested inside the guard")
	var shared := src.substr(guard, power - guard)
	assert_true(shared.contains("overlay_desaturate"),
			"the de-emphasis is outside the POWER branch")
	assert_true(shared.contains("overlay_emission_mult"),
			"and so is the emissive pull-down")
	assert_true(_src(GROUND).contains("sc_overlay_mode"),
			"the ground greys back too, or only the buildings look overlaid")


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
