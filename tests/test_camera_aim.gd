extends SimTest
## Wave 18 (doc 98 §54, doc 12 §2.23.7, doc 93 §AM) — the AIM-HEIGHT RAMP.
##
## The pitch band alone could not do what it was built for: this rig looks AT THE
## FOCUS, the focus is on the ground, so the horizon sits `pitch` above the view
## axis and the 12° floor still framed 79 % pavement with the towers cropped off
## the TOP edge. The ramp lifts the LOOK-AT point instead. Everything below is
## headless: no scene tree, no `Camera3D`, no `Input`.

const DOC_FOV_DEG := 40.0
const REF_VIEWPORT := Vector2(880.0, 400.0)
const WORLD_896 := {"tile_meters": 8, "block_tiles": 16, "size_blocks": [7, 7]}
const TILE_M := 8.0

## doc 11 §2.6 / data/building_shapes.json — the storey height every archetype's
## mesh is generated from.
const FLOOR_HEIGHT_M := 3.5


func _camera() -> CameraState:
	var cfg := UIConfig.load_from_files()
	return CameraState.new(cfg.camera(), cfg.projection_fov_deg(DOC_FOV_DEG), WORLD_896)


func _tan_half_v(cam: CameraState) -> float:
	return tan(deg_to_rad(cam.fov_deg) * 0.5)


# ---------------------------------------------------------------------------
# 1. AUTO, and the whole top-down half, are the camera that shipped
# ---------------------------------------------------------------------------

func test_bias_zero_lifts_nothing_and_the_rig_is_bit_identical() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(400.0, 0.0, 400.0))
	cam.yaw = deg_to_rad(45.0)
	for i in range(0, 21):
		var t := float(i) / 20.0
		cam.set_zoom_t(t)
		cam.clear_pitch_bias()
		assert_eq(cam.aim_height_m(), 0.0, "AUTO lifts nothing at t=%f" % t)
		assert_eq(cam.view_pitch_rad(), cam.pitch_rad(),
				"AUTO view pitch IS the orbit pitch, to the bit, at t=%f" % t)
		assert_true(cam.camera_basis().is_equal_approx(cam.orbit_basis()),
				"AUTO camera basis IS the rig arm at t=%f" % t)
		assert_eq(cam.aim_point(), cam.focus, "AUTO looks at the focus itself")
		# The whole DOWN half of the axis is the same promise: a top-down lean
		# already frames what the player asked for, so the ramp stays out of it.
		for bias: float in [-0.25, -0.6, -1.0]:
			cam.set_pitch_bias(bias)
			assert_eq(cam.aim_height_m(), 0.0,
					"a downward lean lifts nothing (bias %f, t=%f)" % [bias, t])
			assert_eq(cam.view_pitch_rad(), cam.pitch_rad(),
					"…and its view pitch is its orbit pitch")


func test_auto_camera_position_and_transform_are_the_pre_wave_18_rig() -> void:
	# doc 11 §2.5's convention, asserted against the hand-built transform: the
	# ramp may not move the ARM, only where it points.
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(100.0, 0.0, 200.0))
	for t: float in [0.0, 0.42, 0.5, 1.0]:
		cam.set_zoom_t(t)
		for yaw_deg: float in [0.0, 45.0, -135.0]:
			cam.yaw = deg_to_rad(yaw_deg)
			var d := cam.distance()
			for bias: float in [0.0, 0.5, 1.0, -1.0]:
				cam.clear_pitch_bias()
				if not is_zero_approx(bias):
					cam.set_pitch_bias(bias)
				var p := cam.pitch_rad()
				var want := cam.focus + Vector3(
						d * cos(p) * sin(cam.yaw), d * sin(p), d * cos(p) * cos(cam.yaw))
				assert_true(cam.camera_position().distance_to(want) < 0.0005,
						"the arm still places the camera at t=%f bias=%f" % [t, bias])
				assert_almost_eq(cam.camera_position().y, d * sin(p), 0.0005,
						"height is still D·sin(orbit pitch)")


# ---------------------------------------------------------------------------
# 2. The full lean composes the frame the way the data says it does
# ---------------------------------------------------------------------------

func test_the_full_lean_leaves_the_ground_in_the_authored_bottom_share() -> void:
	# Z0 is the pose the 2026-09-02 complaint was taken at and the one zoom whose
	# `reach_up` is 1.0, so the authored framing lands there exactly. Asserted
	# twice: once on the angle, once on where the horizon is DRAWN.
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(400.0, 0.0, 400.0))
	cam.set_zoom_t(0.0)
	cam.yaw = 0.0
	assert_almost_eq(cam.reach_up_at(0.0), 1.0, 0.000001, "Z0 reaches the whole band")
	cam.set_pitch_bias(1.0)
	assert_almost_eq(cam.pitch_deg(), 12.0, 0.0001, "the orbit pitch is still the 12° floor")
	var frac := cam.aim_up_ground_frac
	var want_view := -rad_to_deg(atan((1.0 - 2.0 * frac) * _tan_half_v(cam)))
	assert_almost_eq(cam.view_pitch_deg(), want_view, 0.0001,
			"the view axis rises to -6.92°, i.e. ABOVE horizontal")
	assert_true(cam.view_pitch_deg() < 0.0, "the camera is looking up")
	assert_almost_eq(cam.aim_height_m(), 5.879, 0.002,
			"18·(sin12° + cos12°·tan20°/3) = 5.88 m up the facade")
	# What is DRAWN: a ground point far enough away to be the horizon projects to
	# `1 − frac` of the way down the frame.
	var horizon := cam.focus + cam.ground_forward() * 1.0e6
	var shot: Dictionary = cam.project_to_screen(horizon, REF_VIEWPORT)
	assert_false(bool(shot["behind"]), "the horizon is in front of the camera")
	var y: float = (shot["position"] as Vector2).y
	assert_almost_eq(y / REF_VIEWPORT.y, 1.0 - frac, 0.001,
			"the horizon is drawn 66.7 %% down the frame — pavement in the bottom third")
	# Before the ramp it was 20.8 % down and the ground owned the other 79 %.
	cam.clear_pitch_bias()
	cam.set_pitch_bias(1.0)
	cam.aim_up_anchor_ndc = 0.0   # the anchor may not leave the AXIS -> aim 0
	var was: Dictionary = cam.project_to_screen(horizon, REF_VIEWPORT)
	assert_almost_eq((was["position"] as Vector2).y / REF_VIEWPORT.y, 0.208, 0.002,
			"the same 12° floor without the ramp: horizon a fifth down, 79 % pavement")


func test_the_far_lean_aims_at_the_tall_archetype_roofline() -> void:
	# The authored 1/3 is checked against doc 02, not against taste: the
	# uncapped full lean at the far pose lands on the roof of the tallest thing
	# the roster can build. If doc 02 grows a taller archetype, or doc 11 moves
	# the storey height, this test is the one that says the fraction is stale.
	var cam := _camera()
	var t := 1.0
	var p := deg_to_rad(cam.pitch_floor_deg_at(t))
	var d := cam.distance_at(t)
	var aim := d * (sin(p) + cos(p) * (1.0 - 2.0 * cam.aim_up_ground_frac) * _tan_half_v(cam))
	assert_almost_eq(aim, 217.4, 0.1, "420·(sin24° + cos24°·tan20°/3)")
	var parsed: Variant = JSON.parse_string(
			FileAccess.get_file_as_string("res://data/building_shapes.json"))
	assert_true(parsed is Dictionary, "data/building_shapes.json parses")
	var shapes: Dictionary = parsed
	assert_almost_eq(float(shapes["floor_height_m"]), FLOOR_HEIGHT_M, 0.0001,
			"doc 11's storey height")
	var high_rise: Array = []
	for entry: Variant in (shapes["archetypes"] as Array):
		if str((entry as Dictionary)["id"]) == "high_rise":
			high_rise = (entry as Dictionary)["levels"]
	assert_true(high_rise.size() >= 5, "the roster still has a high_rise ladder")
	var l5 := float((high_rise[4] as Dictionary)["floors"]) * FLOOR_HEIGHT_M
	assert_almost_eq(l5, 217.0, 0.0001,
			"high_rise L5 — 62 floors × 3.5 m, doc 02 §2.3's five-rung roster maximum "
			+ "and the same 217 m tower doc 11 §2.5 works its LOD example against")
	assert_true(absf(aim - l5) < 0.5,
			"the far lean aims at that roofline to within 0.5 m (got %.2f vs %.2f)"
			% [aim, l5])
	# §2.14's sixth rung is taller still (78 floors = 273 m) and is deliberately
	# NOT the scale: it is city-level gated growth stock, not the pose the far
	# zoom is composed against.
	assert_almost_eq(float((high_rise[5] as Dictionary)["floors"]) * FLOOR_HEIGHT_M,
			273.0, 0.0001, "the §2.14 sixth rung, named so the choice is on the record")


func test_the_reach_curve_still_compresses_the_lean_in_the_aim() -> void:
	# The aim rides the SAME reach() the pitch lean does, so the two halves of
	# the axis can never disagree about how far this zoom is allowed to lean.
	# The quantity that carries the composition is the VIEW ANGLE: the derived
	# look-at HEIGHT is not a proxy for it and is not asserted as one — at Z2 a
	# full lean aims LOWER in metres than a half lean (144.0 m against 149.5 m)
	# while looking 20° further up, because the camera itself has dropped from
	# 286.5 m to 170.8 m on the way there.
	var cam := _camera()
	cam.bounds_enabled = false
	for t: float in [0.0, 0.5, 1.0]:
		cam.set_zoom_t(t)
		cam.set_pitch_bias(1.0)
		var full := cam.view_pitch_deg()
		assert_true(cam.aim_height_m() > 0.0, "a full lean lifts the aim at t=%f" % t)
		cam.set_pitch_bias(0.5)
		var half := cam.view_pitch_deg()
		assert_true(full < half, "a whole lean looks further up than half of one at t=%f" % t)
		assert_true(cam.aim_height_m() > 0.0, "…and half a lean still lifts")
		cam.clear_pitch_bias()
		assert_true(half < cam.view_pitch_deg(), "…and half of one looks up from AUTO")
		assert_eq(cam.aim_height_m(), 0.0, "…which lifts nothing at all")
	# Halving the FAR reach shortens the far lean in the aim exactly as it does
	# in the pitch: same bias, same zoom, a strictly lower view axis.
	var narrow := _camera()
	narrow.bounds_enabled = false
	narrow.pitch_reach_up_far = 0.5
	for t: float in [0.5, 0.75, 1.0]:
		cam.set_zoom_t(t)
		cam.set_pitch_bias(1.0)
		narrow.set_zoom_t(t)
		narrow.set_pitch_bias(1.0)
		assert_true(narrow.reach_up_at(t) < cam.reach_up_at(t), "the reach really narrowed")
		assert_true(narrow.view_pitch_deg() > cam.view_pitch_deg(),
				"a narrower reach leaves the view axis lower at t=%f" % t)
		assert_true(narrow.pitch_deg() > cam.pitch_deg(),
				"…exactly as it leaves the orbit pitch steeper")


func test_the_composition_is_monotone_in_the_lean() -> void:
	# What the slider promises is that pushing UP only ever looks further up.
	# The invariant is on the VIEW ANGLE, which together with the camera position
	# is all the frame is. It is NOT on the derived look-at height, and that is
	# deliberate: the orbit pitch falls under the lean and takes both the camera
	# height and `R` with it, so the height can fall while the axis rises.
	var cam := _camera()
	cam.bounds_enabled = false
	for t: float in [0.0, 0.25, 0.42, 0.5, 0.75, 1.0]:
		cam.set_zoom_t(t)
		var prev_view := 999.0
		for i in range(0, 41):
			var bias := float(i) / 40.0
			cam.clear_pitch_bias()
			if bias > 0.0:
				cam.set_pitch_bias(bias)
			assert_true(cam.aim_height_m() >= 0.0,
					"the ramp never aims below the ground plane")
			assert_true(cam.view_pitch_deg() < prev_view + 0.000001,
					"the view axis only ever rises with the lean (t=%f bias=%f)"
					% [t, bias])
			prev_view = cam.view_pitch_deg()


# ---------------------------------------------------------------------------
# 3. The guards: the anchor stays on screen, the camera stays out of the walls
# ---------------------------------------------------------------------------

func test_the_focus_anchor_never_leaves_the_frame() -> void:
	# The focus is the pan, pinch, twist and `focus_on()` anchor. `aim_up_anchor_ndc`
	# is the cap that keeps it drawable at every zoom and every lean.
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(400.0, 0.0, 400.0))
	for yaw_deg: float in [0.0, 45.0, 137.0]:
		cam.yaw = deg_to_rad(yaw_deg)
		for i in range(0, 11):
			var t := float(i) / 10.0
			cam.set_zoom_t(t)
			for j in range(0, 11):
				var bias := float(j) / 10.0
				cam.clear_pitch_bias()
				if bias > 0.0:
					cam.set_pitch_bias(bias)
				var shot: Dictionary = cam.project_to_screen(cam.focus, REF_VIEWPORT)
				assert_false(bool(shot["behind"]), "the focus is in front of the camera")
				var y: float = (shot["position"] as Vector2).y
				assert_true(y >= -0.01 and y <= REF_VIEWPORT.y + 0.01,
						"the anchor is on screen at t=%f bias=%f (y=%f)" % [t, bias, y])


func test_the_camera_is_never_inside_a_ground_floor_at_any_lean() -> void:
	# The reason this is a PURE aim lift: the arm does not move, so Wave 17's
	# `18·sin12° = 3.74 m > 3.5 m` clearance holds unchanged at every bias.
	var cam := _camera()
	cam.bounds_enabled = false
	var lowest := 1.0e9
	for i in range(0, 41):
		var t := float(i) / 40.0
		cam.set_zoom_t(t)
		for j in range(-10, 11):
			var bias := float(j) / 10.0
			cam.clear_pitch_bias()
			if not is_zero_approx(bias):
				cam.set_pitch_bias(bias)
			lowest = minf(lowest, cam.camera_position().y)
	assert_almost_eq(lowest, 18.0 * sin(deg_to_rad(12.0)), 0.001,
			"the lowest reachable camera is still the Z0 floor's 3.74 m")
	assert_true(lowest > FLOOR_HEIGHT_M,
			"…which clears doc 11 §2.6's 3.5 m ground floor")


# ---------------------------------------------------------------------------
# 4. Picking, projection and the scale still agree with what is drawn
# ---------------------------------------------------------------------------

func test_a_tap_resolves_to_the_tile_it_visually_covers() -> void:
	# THE pick-agreement test (doc 93 §AM3). The ramp moves where the ray points,
	# not the ray math: a world tile is projected to the screen and the screen
	# point is cast back, at AUTO and at the floor, at three zooms.
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(448.0, 0.0, 448.0))
	cam.yaw = deg_to_rad(45.0)
	var checked := 0
	for t: float in [0.0, 0.42, 1.0]:
		cam.set_zoom_t(t)
		for lean: float in [0.0, 1.0]:
			cam.clear_pitch_bias()
			if lean > 0.0:
				cam.set_pitch_bias(lean)
			for ring: float in [0.25, 0.6, 1.0]:
				# A tile centre out in front of the camera, on the ground.
				var reach := cam.distance() * ring
				var world := cam.focus + cam.ground_forward() * reach
				world = Vector3(
						(floorf(world.x / TILE_M) + 0.5) * TILE_M, 0.0,
						(floorf(world.z / TILE_M) + 0.5) * TILE_M)
				var shot: Dictionary = cam.project_to_screen(world, REF_VIEWPORT)
				if bool(shot["behind"]):
					continue
				var screen: Vector2 = shot["position"]
				if screen.x < 0.0 or screen.x > REF_VIEWPORT.x \
						or screen.y < 0.0 or screen.y > REF_VIEWPORT.y:
					continue
				var answer := cam.ground_hit(screen, REF_VIEWPORT)
				assert_true(bool(answer["hit"]),
						"the pixel a tile is drawn on hits the ground (t=%f lean=%f)"
						% [t, lean])
				var back: Vector3 = answer["position"]
				assert_true(back.distance_to(world) < 0.01,
						"the tap lands on the tile it covers (t=%f lean=%f, off by %f m)"
						% [t, lean, back.distance_to(world)])
				assert_eq(floorf(back.x / TILE_M), floorf(world.x / TILE_M), "same tile x")
				assert_eq(floorf(back.z / TILE_M), floorf(world.z / TILE_M), "same tile z")
				checked += 1
	assert_true(checked >= 12, "the sweep actually checked something (%d)" % checked)


func test_a_screen_point_round_trips_through_the_ground_and_back() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(448.0, 0.0, 448.0))
	cam.set_zoom_t(0.0)
	cam.yaw = deg_to_rad(45.0)
	cam.set_pitch_bias(1.0)
	# The bottom of the frame at the floor is the pavement the ramp keeps.
	for frac: float in [0.80, 0.90, 1.00]:
		for col: float in [0.15, 0.5, 0.85]:
			var screen := Vector2(REF_VIEWPORT.x * col, REF_VIEWPORT.y * frac)
			var answer := cam.ground_hit(screen, REF_VIEWPORT)
			assert_true(bool(answer["hit"]), "pavement at %.0f %% down" % (frac * 100.0))
			var shot: Dictionary = cam.project_to_screen(answer["position"], REF_VIEWPORT)
			assert_false(bool(shot["behind"]))
			assert_true((shot["position"] as Vector2).distance_to(screen) < 0.02,
					"ray and projection are inverses at the floor")


func test_m_per_dp_is_the_scale_the_projection_actually_draws() -> void:
	# `m_per_dp` claims to be metres of ground per dp at the focus, along
	# screen-right. Proved against `project_to_screen` itself rather than against
	# its own formula, at AUTO and at the floor.
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(448.0, 0.0, 448.0))
	for yaw_deg: float in [0.0, 45.0, -110.0]:
		cam.yaw = deg_to_rad(yaw_deg)
		for t: float in [0.0, 0.42, 1.0]:
			cam.set_zoom_t(t)
			for lean: float in [0.0, 0.5, 1.0]:
				cam.clear_pitch_bias()
				if lean > 0.0:
					cam.set_pitch_bias(lean)
				var span_m := cam.distance() * 0.05
				var a: Dictionary = cam.project_to_screen(cam.focus, REF_VIEWPORT)
				var b: Dictionary = cam.project_to_screen(
						cam.focus + cam.ground_right() * span_m, REF_VIEWPORT)
				assert_false(bool(a["behind"]) or bool(b["behind"]))
				var dp: float = (b["position"] as Vector2).x - (a["position"] as Vector2).x
				assert_almost_eq((a["position"] as Vector2).y, (b["position"] as Vector2).y,
						0.001, "screen-right is horizontal on screen at every lean")
				assert_almost_eq(span_m / dp, cam.m_per_dp(REF_VIEWPORT), 0.000001,
						"m_per_dp is the drawn scale (t=%f lean=%f)" % [t, lean])


func test_the_view_basis_points_at_the_aim_point() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(300.0, 0.0, 500.0))
	for yaw_deg: float in [0.0, 45.0, 200.0]:
		cam.yaw = deg_to_rad(yaw_deg)
		for t: float in [0.0, 0.5, 1.0]:
			cam.set_zoom_t(t)
			for lean: float in [0.0, 0.35, 1.0]:
				cam.clear_pitch_bias()
				if lean > 0.0:
					cam.set_pitch_bias(lean)
				var forward := -cam.camera_basis().z
				var to_aim := (cam.aim_point() - cam.camera_position()).normalized()
				assert_true(forward.distance_to(to_aim) < 0.00001,
						"the camera looks at focus + (0, aim, 0) at t=%f lean=%f"
						% [t, lean])


# ---------------------------------------------------------------------------
# 5. Persistence, and the renderer's read of the frustum
# ---------------------------------------------------------------------------

func test_the_save_round_trip_restores_the_pitch_and_the_aim() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(320.0, 0.0, 512.0))
	cam.set_zoom_t(0.31)
	cam.yaw = deg_to_rad(135.0)
	cam.set_pitch_bias(0.8)
	var blob := cam.to_dict()
	assert_eq(str(blob["pitch_mode"]), "manual", "a lean saves as manual")
	var back := _camera()
	back.bounds_enabled = false
	back.from_dict(blob)
	assert_almost_eq(back.pitch_bias, cam.pitch_bias, 0.000001, "same bias back")
	assert_almost_eq(back.pitch_deg(), cam.pitch_deg(), 0.000001, "same orbit angle back")
	assert_almost_eq(back.aim_height_m(), cam.aim_height_m(), 0.000001,
			"same aim height back — it is DERIVED, so the save carries no new key")
	assert_almost_eq(back.view_pitch_deg(), cam.view_pitch_deg(), 0.000001,
			"…and therefore the same composition")
	# AUTO round-trips to a ramp that lifts nothing.
	cam.clear_pitch_bias()
	back.from_dict(cam.to_dict())
	assert_true(back.is_pitch_auto())
	assert_eq(back.aim_height_m(), 0.0, "AUTO restores to no lift at all")


func test_the_pitch_cull_reads_the_frustum_and_a_lifted_aim_leaves_it_standing() -> void:
	# doc 11 §2.5b's cull takes its angle off the camera BASIS, which the ramp
	# now tips, so it follows the aim for free. Below the half-FOV the top ray
	# clears the horizon and the reach is INF — which is the same answer the
	# "no pitch supplied" sentinel gives, so a negative view pitch cannot
	# accidentally shorten the draw distance. (doc 93 §AM4.)
	var model := RenderStateModel.new({
		"camera": {"fov_deg": 40.0},
		"lod": {"far_cull_m": 1200.0, "medium_max_m": 420.0,
			"pitch_cull": {"enabled": true, "floor_m": 420.0, "max_aspect": 2.4,
				"slack": [[34.0, 1.1], [62.0, 1.06]]}},
	})
	assert_almost_eq(model.far_cull_m, 1200.0, 0.0001, "the preset's own far cull")
	model.set_camera_pose(370.8, 62.0, 1.78)
	var culled := model.active_far_cull_m
	assert_true(culled < model.far_cull_m, "at 62° the cull bites")
	for looking_up: float in [-6.92, -3.68, 0.0, 4.0, 19.9]:
		model.set_camera_pose(3.74, looking_up, 1.78)
		assert_almost_eq(model.active_far_cull_m, model.far_cull_m, 0.0001,
				"a frustum that sees sky reaches forever (view pitch %f)" % looking_up)
	model.set_camera_pose(3.74, -1.0, 1.78)
	assert_almost_eq(model.active_far_cull_m, model.far_cull_m, 0.0001,
			"the -1 'no pitch supplied' sentinel lands on the same answer")
