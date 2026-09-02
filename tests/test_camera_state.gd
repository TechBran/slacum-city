extends SimTest
## Doc 12 P1-30: `CameraState` — the §2.16 interaction model, checked against the
## doc's own worked numbers (Z0/Z1/Z2 poses, the regenerated coverage table, the
## 1:1 ground lock, momentum, bounds and yaw snap). Everything here is headless:
## no scene tree, no Camera3D, no Input.

## Doc 12 §2.16 derives its coverage table from doc 11's projection, quoted
## "at the time of writing" as fov_deg 40 in `data/render.json`. Test 5b's job is
## to fail loudly if doc 11 retunes rather than leave a stale table.
const DOC_FOV_DEG := 40.0

## Doc 12 §2.16's reference layout box; the coverage table is derived at this
## aspect (880/400 = 2.2 → horizontal half-angle 38.69°).
const REF_VIEWPORT := Vector2(880.0, 400.0)

const WORLD_896 := {"tile_meters": 8, "block_tiles": 16, "size_blocks": [7, 7]}


func _config() -> UIConfig:
	return UIConfig.load_from_files()


func _fov_deg(cfg: UIConfig) -> float:
	return cfg.projection_fov_deg(DOC_FOV_DEG)


func _camera(cfg: UIConfig = null) -> CameraState:
	var c := cfg if cfg != null else _config()
	return CameraState.new(c.camera(), _fov_deg(c), WORLD_896)


# ---------------------------------------------------------------------------
# doc 12 test 5 — zoom curve + pitch curve
# ---------------------------------------------------------------------------

func test_zoom_curve_endpoints_and_worked_values() -> void:
	var cam := _camera()
	assert_almost_eq(cam.d_min_m, 18.0, 0.0001, "D_MIN from data/ui.json")
	assert_almost_eq(cam.d_max_m, 420.0, 0.0001, "D_MAX from data/ui.json")
	assert_almost_eq(cam.distance_at(0.0), 18.0, 0.0001, "dist(0)")
	assert_almost_eq(cam.distance_at(0.42), 67.6, 0.1, "dist(0.42) — the default framing")
	assert_almost_eq(cam.distance_at(0.5), 86.9, 0.1, "dist(0.5)")
	assert_almost_eq(cam.distance_at(1.0), 420.0, 0.0001, "dist(1)")
	# The retired 71 m default was never on the curve (C-63).
	assert_true(absf(cam.distance_at(0.42) - 71.0) > 3.0, "71 m is not on the curve")


func test_zoom_curve_is_invertible_and_monotonic() -> void:
	var cam := _camera()
	var prev := -1.0
	for i in range(0, 101):
		var t := float(i) / 100.0
		var d := cam.distance_at(t)
		assert_true(d > prev, "dist(t) strictly increasing at t=%f" % t)
		prev = d
		assert_almost_eq(cam.zoom_t_for_distance(d), t, 0.00001, "t(dist(t)) == t at %f" % t)


func test_pitch_curve() -> void:
	var cam := _camera()
	assert_almost_eq(cam.pitch_deg_at(0.0), 34.0, 0.0001, "pitch(0)")
	assert_almost_eq(cam.pitch_deg_at(0.42), 44.67, 0.01, "pitch(0.42) = 34 + 28*0.3810")
	assert_almost_eq(cam.pitch_deg_at(0.5), 48.0, 0.0001, "pitch(0.5)")
	assert_almost_eq(cam.pitch_deg_at(1.0), 62.0, 0.0001, "pitch(1)")
	var prev := -1.0
	for i in range(0, 101):
		var p := cam.pitch_deg_at(float(i) / 100.0)
		assert_true(p >= prev, "pitch monotonic")
		prev = p


# ---------------------------------------------------------------------------
# The Z0 / Z1 / Z2 reference poses (doc 12 §2.16, doc 11 §2.5)
# ---------------------------------------------------------------------------

func test_reference_poses_z0_z1_z2() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3.ZERO)
	cam.yaw = 0.0
	var expected := [
		{"t": 0.0, "dist": 18.0, "pitch": 34.0, "height": 10.1},
		{"t": 0.42, "dist": 67.6, "pitch": 44.67, "height": 47.5},
		{"t": 0.5, "dist": 86.9, "pitch": 48.0, "height": 64.6},
		{"t": 1.0, "dist": 420.0, "pitch": 62.0, "height": 370.8},
	]
	for row: Dictionary in expected:
		cam.set_zoom_t(row["t"])
		assert_almost_eq(cam.distance(), row["dist"], 0.1, "D at t=%s" % row["t"])
		assert_almost_eq(cam.pitch_deg(), row["pitch"], 0.01, "pitch at t=%s" % row["t"])
		assert_almost_eq(cam.height_m(), row["height"], 0.1, "camera height at t=%s" % row["t"])
		# The camera sits exactly D away from the focus, at height D*sin(p).
		var pos := cam.camera_position()
		assert_almost_eq(pos.distance_to(cam.focus), cam.distance(), 0.001,
				"|camera - focus| == D")
		assert_almost_eq(pos.y, row["height"], 0.1, "y == D*sin(pitch)")


func test_camera_transform_matches_doc11_rig_convention() -> void:
	# doc 11 §2.5: Camera3D at local (0, D*sin p, D*cos p) under a yaw pivot.
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(100.0, 0.0, 200.0))
	cam.set_zoom_t(0.5)
	for yaw_deg: float in [0.0, 45.0, 90.0, -135.0]:
		cam.yaw = deg_to_rad(yaw_deg)
		var d := cam.distance()
		var p := cam.pitch_rad()
		var want := cam.focus + Vector3(
				d * cos(p) * sin(cam.yaw), d * sin(p), d * cos(p) * cos(cam.yaw))
		assert_true(cam.camera_position().distance_to(want) < 0.0005,
				"camera position at yaw %f" % yaw_deg)
		assert_almost_eq(cam.camera_rotation().x, -p, 0.00001, "rig pitch is -pitch")
		assert_almost_eq(cam.camera_rotation().y, cam.yaw, 0.00001, "rig yaw")


func test_worked_ground_coverage_table() -> void:
	# doc 12 §2.16's regenerated table, derived (not authored) from doc 11's FOV.
	var cfg := _config()
	assert_almost_eq(_fov_deg(cfg), DOC_FOV_DEG, 0.0001,
			"doc 11 data/render.json fov_deg — if this moved, doc 12 §2.16's coverage table is stale (C-63 / test 5b)")
	var cam := _camera(cfg)
	cam.bounds_enabled = false
	cam.set_focus(Vector3.ZERO)
	cam.yaw = 0.0
	var rows := [
		{"t": 0.0, "depth": 33.1, "width": 28.8},
		{"t": 0.42, "depth": 80.8, "width": 108.3},
		{"t": 0.5, "depth": 95.4, "width": 139.2},
		{"t": 1.0, "depth": 359.7, "width": 672.6},
	]
	for row: Dictionary in rows:
		cam.set_zoom_t(row["t"])
		var w := REF_VIEWPORT.x
		var h := REF_VIEWPORT.y
		var far_edge := cam.screen_to_ground(Vector2(w * 0.5, 0.0), REF_VIEWPORT)
		var near_edge := cam.screen_to_ground(Vector2(w * 0.5, h), REF_VIEWPORT)
		var depth := far_edge.distance_to(near_edge)
		var left := cam.screen_to_ground(Vector2(0.0, h * 0.5), REF_VIEWPORT)
		var right := cam.screen_to_ground(Vector2(w, h * 0.5), REF_VIEWPORT)
		var width := left.distance_to(right)
		assert_almost_eq(depth, row["depth"], 0.5, "ground depth at t=%s" % row["t"])
		assert_almost_eq(width, row["width"], 0.5, "ground width at t=%s" % row["t"])
	# 2*tan(38.69°) = 1.6015 -> 672.6 m at t = 1 (doc 12 test 5b).
	cam.set_zoom_t(1.0)
	assert_almost_eq(cam.m_per_dp(REF_VIEWPORT) * REF_VIEWPORT.x, 672.6, 0.5,
			"width at focus == 1.6015 * D_MAX")


# ---------------------------------------------------------------------------
# doc 12 test 6 — exact 1:1 world lock
# ---------------------------------------------------------------------------

func test_pan_ground_lock_reprojects_within_half_dp() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x51ACC0DE
	var vp := REF_VIEWPORT
	for _i in range(0, 50):
		cam.set_focus(Vector3(rng.randf_range(-200.0, 200.0), 0.0, rng.randf_range(-200.0, 200.0)))
		cam.yaw = rng.randf_range(-PI, PI)
		cam.set_zoom_t(rng.randf())
		var p0 := Vector2(rng.randf_range(40.0, vp.x - 40.0), rng.randf_range(40.0, vp.y - 40.0))
		var p1 := Vector2(rng.randf_range(40.0, vp.x - 40.0), rng.randf_range(40.0, vp.y - 40.0))
		var anchor := cam.screen_to_ground(p0, vp)
		cam.begin_pan(p0, vp)
		cam.update_pan(p1, vp, 1.0 / 60.0)
		var reprojected: Dictionary = cam.project_to_screen(anchor, vp)
		assert_false(reprojected["behind"], "anchor stayed in front of the camera")
		var err: float = (reprojected["position"] as Vector2).distance_to(p1)
		assert_true(err < 0.5, "anchor re-projects within 0.5 dp (got %f)" % err)
		cam.end_pan()


func test_pan_moves_focus_exactly_n_ground_metres() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(400.0, 0.0, 400.0))
	cam.set_zoom_t(0.42)
	cam.yaw = deg_to_rad(45.0)
	# (a) direct: N metres of ground displacement is N metres of focus.
	for n: float in [1.0, 17.5, 250.0]:
		var before := cam.focus
		cam.pan_by_ground_delta(Vector3(n, 0.0, 0.0))
		assert_almost_eq(cam.focus.distance_to(before), n, 0.000001,
				"pan of %f m moved the focus %f m" % [n, cam.focus.distance_to(before)])
	# (b) via touch: the focus moves by exactly the ground delta between the two
	# touch points, at any zoom/pitch/yaw.
	var vp := REF_VIEWPORT
	for t: float in [0.0, 0.42, 1.0]:
		cam.set_zoom_t(t)
		var p0 := Vector2(300.0, 250.0)
		var p1 := Vector2(560.0, 140.0)
		var g0 := cam.screen_to_ground(p0, vp)
		var g1 := cam.screen_to_ground(p1, vp)
		var before := cam.focus
		cam.begin_pan(p0, vp)
		cam.update_pan(p1, vp, 1.0 / 60.0)
		var moved := cam.focus - before
		assert_true(moved.distance_to(g0 - g1) < 0.0005,
				"focus delta == ground delta at t=%f" % t)
		cam.end_pan()
		cam.cancel_momentum()


func test_screen_to_ground_round_trips_through_projection() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(64.0, 0.0, -32.0))
	cam.set_zoom_t(0.7)
	cam.yaw = deg_to_rad(-120.0)
	for p: Vector2 in [Vector2(10.0, 30.0), Vector2(440.0, 200.0), Vector2(870.0, 390.0)]:
		var g := cam.screen_to_ground(p, REF_VIEWPORT)
		assert_almost_eq(g.y, 0.0, 0.000001, "ground hit lies on y = 0")
		var back: Dictionary = cam.project_to_screen(g, REF_VIEWPORT)
		assert_false(back["behind"], "ground point projects in front")
		assert_true((back["position"] as Vector2).distance_to(p) < 0.01,
				"screen -> ground -> screen round trip")


# ---------------------------------------------------------------------------
# Zoom about the gesture centroid
# ---------------------------------------------------------------------------

func test_pinch_zoom_keeps_the_ground_point_under_the_centroid() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(200.0, 0.0, 200.0))
	cam.yaw = deg_to_rad(30.0)
	cam.set_zoom_t(0.5)
	var vp := REF_VIEWPORT
	var centroid := Vector2(620.0, 130.0)
	var anchor := cam.screen_to_ground(centroid, vp)
	cam.zoom_about_point(centroid, vp, 0.2)
	assert_true(cam.zoom_t < 0.5, "zoomed in")
	var after := cam.screen_to_ground(centroid, vp)
	assert_true(anchor.distance_to(after) < 0.01, "centroid ground point is invariant")

	# The doc's pinch step: dist scales by span_prev/span_now about the centroid.
	cam.set_zoom_t(0.5)
	var d_before := cam.distance()
	var anchor2 := cam.screen_to_ground(centroid, vp)
	cam.begin_pan(centroid, vp)
	cam.apply_pinch(100.0, 200.0, centroid, vp)  # fingers doubled their span
	assert_almost_eq(cam.distance(), d_before * 0.5, 0.001, "span doubled -> distance halved")
	assert_true(anchor2.distance_to(cam.screen_to_ground(centroid, vp)) < 0.01,
			"engage-time anchor returns under the centroid")
	cam.end_pan()


func test_double_tap_zoom_step() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_zoom_t(0.5)
	var t_before := cam.zoom_t
	cam.step_zoom(Vector2(440.0, 200.0), REF_VIEWPORT, 1)
	assert_almost_eq(cam.zoom_t, t_before - 0.18, 0.000001, "double tap zooms in 0.18 t")
	cam.step_zoom(Vector2(440.0, 200.0), REF_VIEWPORT, -1)
	assert_almost_eq(cam.zoom_t, t_before, 0.000001, "two-finger tap zooms back out")
	cam.set_zoom_t(0.1)
	cam.step_zoom(Vector2(440.0, 200.0), REF_VIEWPORT, 1)
	assert_almost_eq(cam.zoom_t, 0.0, 0.000001, "clamped at t = 0")


# ---------------------------------------------------------------------------
# doc 12 test 7 — momentum
# ---------------------------------------------------------------------------

func test_momentum_decay_is_deterministic() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3.ZERO)
	assert_true(cam.start_momentum(Vector3(60.0, 0.0, 0.0)), "60 m/s clears the 3 m/s floor")
	var elapsed := 0.0
	var steps := 0
	while cam.is_coasting() and steps < 600:
		cam.advance(1.0 / 60.0)
		elapsed += 1.0 / 60.0
		steps += 1
	assert_false(cam.is_coasting(), "momentum stopped")
	assert_almost_eq(cam.focus.x, 10.0, 0.2, "a 60 m/s fling coasts 60/6 = 10 m")
	assert_true(elapsed <= 1.0, "stopped within 1.0 s (took %f)" % elapsed)

	# dt-independence: the closed-form integrator lands in the same place at 30 Hz.
	var cam2 := _camera()
	cam2.bounds_enabled = false
	cam2.set_focus(Vector3.ZERO)
	cam2.start_momentum(Vector3(60.0, 0.0, 0.0))
	var steps2 := 0
	while cam2.is_coasting() and steps2 < 600:
		cam2.advance(1.0 / 30.0)
		steps2 += 1
	assert_almost_eq(cam2.focus.x, cam.focus.x, 0.05, "coast distance is frame-rate independent")


func test_momentum_floor_and_clamp() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	assert_false(cam.start_momentum(Vector3(2.9, 0.0, 0.0)), "below momentum_min_start_m_s")
	assert_true(cam.start_momentum(Vector3(1000.0, 0.0, 0.0)))
	assert_almost_eq(cam.momentum_velocity().length(), 220.0, 0.001, "clamped to momentum_max_m_s")


func test_new_touch_cancels_momentum_in_the_same_frame() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3.ZERO)
	cam.start_momentum(Vector3(0.0, 0.0, 90.0))
	cam.advance(1.0 / 60.0)
	assert_true(cam.is_coasting())
	cam.begin_pan(Vector2(440.0, 200.0), REF_VIEWPORT)
	assert_false(cam.is_coasting(), "any new touch cancels momentum immediately")
	assert_almost_eq(cam.momentum_velocity().length(), 0.0, 0.000001)


func test_velocity_ema_tracks_the_drag() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3.ZERO)
	cam.set_zoom_t(0.42)
	cam.yaw = 0.0
	var vp := REF_VIEWPORT
	cam.begin_pan(Vector2(440.0, 200.0), vp)
	for i in range(1, 11):
		cam.update_pan(Vector2(440.0 - float(i) * 8.0, 200.0), vp, 1.0 / 60.0)
	assert_true(cam.pan_velocity().length() > 0.0, "EMA accumulated a velocity")
	cam.end_pan()
	assert_true(cam.is_coasting(), "a fast flick hands over to momentum")


# ---------------------------------------------------------------------------
# doc 12 test 8 — bounds and the rubber band
# ---------------------------------------------------------------------------

func test_bounds_rubber_band_and_spring() -> void:
	var cam := _camera()
	# A 3x3-block city at the world origin; bounds pad by 2 blocks = 256 m.
	cam.set_owned_land_aabb(Vector2.ZERO, Vector2(384.0, 384.0))
	assert_almost_eq(cam.bounds_max().x, 640.0, 0.0001, "384 + 2 blocks of pad")
	assert_almost_eq(cam.bounds_min().x, -256.0, 0.0001)
	cam.set_focus(Vector3(640.0, 0.0, 192.0))
	cam.begin_pan(Vector2(440.0, 200.0), REF_VIEWPORT)
	cam.pan_by_ground_delta(Vector3(40.0, 0.0, 0.0))
	assert_almost_eq(cam.focus.x, 640.0 + 40.0 * 0.35, 0.0001,
			"over-bound displacement is multiplied by 0.35 while dragging")
	var displacement := cam.focus.x - 640.0
	cam.end_pan()
	assert_true(cam.is_springing(), "release starts the critically damped return")

	var t := 0.0
	var worst_overshoot := 0.0
	var at_040 := -1.0
	while cam.is_springing() and t < 2.0:
		cam.advance(1.0 / 120.0)
		t += 1.0 / 120.0
		worst_overshoot = maxf(worst_overshoot, 640.0 - cam.focus.x)
		if at_040 < 0.0 and t >= 0.40:
			at_040 = cam.focus.x - 640.0
	assert_true(worst_overshoot <= displacement * 0.01,
			"critically damped: overshoot <= 1%% (got %f m)" % worst_overshoot)
	assert_true(at_040 >= 0.0 and at_040 <= displacement * 0.05,
			"at least 95%% recovered by 0.40 s (%f m of %f m left)" % [at_040, displacement])
	assert_false(cam.is_springing(), "settled")
	assert_almost_eq(cam.focus.x, 640.0, 0.001, "returned exactly to the bound")


func test_focus_clamps_to_padded_world_when_idle() -> void:
	var cam := _camera()
	cam.set_owned_land_aabb(Vector2.ZERO, Vector2(896.0, 896.0))
	assert_almost_eq(cam.bounds_max().x, 896.0 + 256.0, 0.0001, "7x7 world + 2 blocks")
	cam.set_focus(Vector3(5000.0, 0.0, -5000.0))
	assert_almost_eq(cam.focus.x, 1152.0, 0.0001)
	assert_almost_eq(cam.focus.z, -256.0, 0.0001)


func test_d_max_eff_from_city_diagonal() -> void:
	var cam := _camera()
	# A single owned block: diagonal 181.02 m * 1.6 = 289.6 m, inside [120, 420].
	cam.set_owned_land_aabb(Vector2.ZERO, Vector2(128.0, 128.0))
	assert_almost_eq(cam.d_max_eff(), 128.0 * sqrt(2.0) * 1.6, 0.01)
	assert_true(cam.max_zoom_t() < 1.0, "zoom-out is limited before D_MAX")
	cam.set_zoom_t(1.0)
	assert_almost_eq(cam.distance(), cam.d_max_eff(), 0.001, "clamped to D_MAX_eff")
	# A degenerate city clamps up to the 120 m floor.
	cam.set_owned_land_aabb(Vector2.ZERO, Vector2.ZERO)
	assert_almost_eq(cam.d_max_eff(), 120.0, 0.0001)
	# The whole 7x7 world clamps down to D_MAX.
	cam.set_owned_land_aabb(Vector2.ZERO, Vector2(896.0, 896.0))
	assert_almost_eq(cam.d_max_eff(), 420.0, 0.0001)


# ---------------------------------------------------------------------------
# doc 12 test 9 — rotation snap
# ---------------------------------------------------------------------------

func _settle_yaw(cam: CameraState) -> void:
	var steps := 0
	while cam.is_snapping_yaw() and steps < 600:
		cam.advance(1.0 / 120.0)
		steps += 1


func test_rotation_snap45() -> void:
	var cam := _camera()
	cam.rotation_mode = CameraState.RotationMode.SNAP45
	for row: Array in [[37.0, 45.0], [68.0, 90.0], [-37.0, -45.0], [10.0, 0.0]]:
		cam.yaw = deg_to_rad(row[0])
		cam.release_twist()
		_settle_yaw(cam)
		assert_almost_eq(rad_to_deg(cam.yaw), row[1], 0.001,
				"snap45: %f -> %f" % [row[0], row[1]])


func test_rotation_snap90_free_and_locked() -> void:
	var cam := _camera()
	cam.rotation_mode = CameraState.RotationMode.SNAP90
	cam.yaw = deg_to_rad(68.0)
	cam.release_twist()
	_settle_yaw(cam)
	assert_almost_eq(rad_to_deg(cam.yaw), 90.0, 0.001, "snap90: 68 -> 90")
	cam.yaw = deg_to_rad(37.0)
	cam.release_twist()
	_settle_yaw(cam)
	assert_almost_eq(rad_to_deg(cam.yaw), 0.0, 0.001, "snap90: 37 -> 0")

	cam.rotation_mode = CameraState.RotationMode.FREE
	cam.yaw = deg_to_rad(37.0)
	assert_false(cam.release_twist(), "free never snaps")
	_settle_yaw(cam)
	assert_almost_eq(rad_to_deg(cam.yaw), 37.0, 0.001)

	cam.rotation_mode = CameraState.RotationMode.LOCKED
	var before := cam.yaw
	assert_false(cam.apply_twist(deg_to_rad(30.0)), "locked ignores twist entirely")
	assert_almost_eq(cam.yaw, before, 0.000001)
	assert_false(cam.release_twist())


func test_twist_is_one_to_one_with_the_fingers() -> void:
	var cam := _camera()
	cam.rotation_mode = CameraState.RotationMode.FREE
	cam.yaw = 0.0
	for _i in range(0, 4):
		cam.apply_twist(deg_to_rad(10.0))
	assert_almost_eq(rad_to_deg(cam.yaw), 40.0, 0.0001, "yaw += delta, 1:1")


func test_yaw_snap_tween_uses_ease_out_back() -> void:
	assert_almost_eq(CameraState.ease_out_back(0.0), 0.0, 0.000001)
	assert_almost_eq(CameraState.ease_out_back(1.0), 1.0, 0.000001)
	var overshot := false
	for i in range(1, 100):
		if CameraState.ease_out_back(float(i) / 100.0) > 1.0:
			overshot = true
	assert_true(overshot, "back easing overshoots before settling")


# ---------------------------------------------------------------------------
# Jumps, follow and persistence
# ---------------------------------------------------------------------------

func test_focus_on_short_hop_tweens_and_lands() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3.ZERO)
	cam.set_zoom_t(0.6)
	cam.focus_on(Vector3(100.0, 0.0, 0.0), 90.0)
	assert_true(cam.is_jumping())
	var steps := 0
	while cam.is_jumping() and steps < 600:
		cam.advance(1.0 / 60.0)
		steps += 1
	assert_almost_eq(cam.focus.x, 100.0, 0.0001)
	assert_almost_eq(cam.distance(), 90.0, 0.01, "landed at the requested distance")
	assert_true(float(steps) / 60.0 <= 0.5, "0.45 s tween")


func test_focus_on_long_hop_arcs_out_then_in() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3.ZERO)
	cam.set_zoom_t(0.3)
	cam.focus_on(Vector3(900.0, 0.0, 0.0), 60.0)
	var peak := cam.zoom_t
	var steps := 0
	while cam.is_jumping() and steps < 600:
		cam.advance(1.0 / 60.0)
		peak = maxf(peak, cam.zoom_t)
		steps += 1
	assert_true(peak > 0.3 + 0.2, "zoom_t bumps up at the arc midpoint (peak %f)" % peak)
	assert_almost_eq(cam.focus.x, 900.0, 0.0001)
	assert_almost_eq(cam.distance(), 60.0, 0.01)
	assert_true(float(steps) / 60.0 <= 0.8, "0.75 s arc")


func test_focus_on_reduce_motion_cuts() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3.ZERO)
	cam.focus_on(Vector3(900.0, 0.0, 0.0), 60.0, true)
	assert_false(cam.is_jumping(), "reduce_motion is a hard cut (A8)")
	assert_almost_eq(cam.focus.x, 900.0, 0.0001)


func test_follow_mode_converges_and_is_cancelled_by_pan() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3.ZERO)
	cam.set_follow_target(Vector3(50.0, 0.0, 0.0))
	for _i in range(0, 120):
		cam.advance(1.0 / 60.0)
	assert_true(cam.focus.distance_to(Vector3(50.0, 0.0, 0.0)) < 0.1, "follow converges")
	cam.begin_pan(Vector2(440.0, 200.0), REF_VIEWPORT)
	assert_false(cam.is_following(), "any manual pan cancels follow")


func test_save_section_round_trip() -> void:
	var cam := _camera()
	cam.set_focus(Vector3(512.0, 0.0, 384.0))
	cam.set_zoom_t(0.42)
	cam.yaw = deg_to_rad(45.0)
	var d := cam.to_dict()
	assert_almost_eq(d["focus_x"], 512.0, 0.0001)
	assert_almost_eq(d["focus_z"], 384.0, 0.0001)
	assert_almost_eq(d["zoom_t"], 0.42, 0.0001)
	assert_almost_eq(d["yaw_deg"], 45.0, 0.0001)
	var restored := _camera()
	restored.from_dict(d)
	assert_almost_eq(restored.focus.x, 512.0, 0.0001)
	assert_almost_eq(restored.focus.z, 384.0, 0.0001)
	assert_almost_eq(restored.zoom_t, 0.42, 0.0001)
	assert_almost_eq(rad_to_deg(restored.yaw), 45.0, 0.0001)


func test_defaults_come_from_data_not_code() -> void:
	var cfg := _config()
	var cam := _camera(cfg)
	var block := cfg.camera()
	assert_almost_eq(cam.zoom_t, UIConfig.get_num(block, "default_zoom_t", -1.0), 0.0001)
	assert_almost_eq(rad_to_deg(cam.yaw), UIConfig.get_num(block, "default_yaw_deg", -1.0), 0.0001)
	assert_eq(cam.rotation_mode, CameraState.RotationMode.SNAP45, "rotation_mode_default")
	assert_almost_eq(cam.distance(),
			UIConfig.get_num(block, "default_zoom_dist_m_derived", -1.0), 0.1,
			"the authored derived default distance matches the curve")


# ---------------------------------------------------------------------------
# doc 12 test 5b (ui.json half) — the two files never restate each other
# ---------------------------------------------------------------------------

func test_ui_json_camera_carries_range_not_projection() -> void:
	var cfg := _config()
	assert_true(cfg.is_valid(), "data/ui.json and data/strings.en.json load: %s"
			% str(cfg.errors))
	var block := cfg.camera()
	for key: String in ["dist_min_m", "dist_max_m", "pitch_near_deg", "pitch_far_deg"]:
		assert_true(block.has(key), "data/ui.json.camera carries %s" % key)
	var offenders := cfg.ui_camera_restates_projection()
	assert_true(offenders.is_empty(),
			"data/ui.json.camera must not restate doc 11's projection: %s" % str(offenders))
	assert_eq(str(block.get("projection_from", "")), "data/render.json",
			"the projection is referenced, not copied (C-63)")
	if cfg.has_render_data():
		var render := cfg.render_data()
		var found := false
		for key: String in ["camera", "projection"]:
			var sub: Variant = render.get(key, null)
			if sub is Dictionary and (sub as Dictionary).has("fov_deg"):
				found = true
		assert_true(found or render.has("fov_deg"),
				"data/render.json owns fov_deg (doc 11 §2.5)")


# ---------------------------------------------------------------------------
# Wave 17 — the manual pitch axis (doc 12 §2.23, doc 98 §43)
# ---------------------------------------------------------------------------

func test_auto_pitch_is_the_curve_to_the_bit() -> void:
	# The axis COMPOSES: a camera nobody tilted is byte-for-byte the camera it
	# was before the axis existed, at every zoom.
	var cam := _camera()
	for i in range(0, 21):
		var t := float(i) / 20.0
		cam.set_zoom_t(t)
		assert_true(cam.is_pitch_auto(), "fresh camera is AUTO at t=%f" % t)
		assert_eq(cam.pitch_deg(), cam.pitch_deg_at(cam.zoom_t),
				"AUTO pitch == pitch(t) exactly at t=%f" % t)


func test_the_lean_reaches_the_authored_band_at_every_zoom() -> void:
	var cam := _camera()
	assert_almost_eq(cam.pitch_manual_min_deg, 12.0, 0.0001, "the floor from data/ui.json")
	assert_almost_eq(cam.pitch_manual_max_deg, 78.0, 0.0001, "the ceiling from data/ui.json")
	for t: float in [0.0, 0.42, 0.5, 1.0]:
		cam.set_zoom_t(t)
		cam.set_pitch_bias(1.0)
		assert_almost_eq(cam.pitch_deg(), cam.pitch_floor_deg_at(t), 0.0001,
				"bias +1 is the floor this zoom allows at t=%f" % t)
		cam.set_pitch_bias(-1.0)
		assert_almost_eq(cam.pitch_deg(), cam.pitch_ceiling_deg_at(t), 0.0001,
				"bias -1 is the ceiling this zoom allows at t=%f" % t)
		cam.set_pitch_bias(0.5)
		assert_almost_eq(cam.pitch_deg(), lerpf(cam.pitch_deg_at(t), cam.pitch_floor_deg_at(t), 0.5),
				0.0001, "half a lean is half way from the curve to the floor at t=%f" % t)
	# Close in, the whole authored band is reachable (reach 1.0 at t = 0).
	cam.set_zoom_t(0.0)
	cam.set_pitch_bias(1.0)
	assert_almost_eq(cam.pitch_deg(), 12.0, 0.0001, "bias +1 at Z0 is the 12° floor")
	assert_almost_eq(cam.height_m(), 18.0 * sin(deg_to_rad(12.0)), 0.001,
			"at the floor a Z0 camera is 3.74 m up — above the 3.5 m ground floor")
	cam.set_pitch_bias(-1.0)
	assert_almost_eq(cam.pitch_deg(), 78.0, 0.0001, "bias -1 at Z0 is the 78° ceiling")


func test_the_middle_detent_is_auto_not_a_bias_that_looks_like_it() -> void:
	var cam := _camera()
	cam.set_pitch_bias(0.03)
	assert_true(cam.is_pitch_auto(), "inside pitch_detent_units lands on AUTO")
	assert_almost_eq(cam.pitch_bias, 0.0, 0.000001)
	cam.set_pitch_bias(0.05)
	assert_false(cam.is_pitch_auto(), "outside it is a lean")
	assert_almost_eq(cam.pitch_bias, 0.05, 0.000001)


func test_set_pitch_deg_solves_the_bias_and_clamps_to_the_band() -> void:
	var cam := _camera()
	for t: float in [0.0, 0.5, 1.0]:
		cam.set_zoom_t(t)
		var lo := cam.pitch_floor_deg_at(t)
		var hi := cam.pitch_ceiling_deg_at(t)
		for k in range(0, 7):
			var deg := lerpf(lo, hi, float(k) / 6.0)
			cam.set_pitch_deg(deg)
			# The middle detent is honoured on the way IN, because
			# `set_pitch_deg` goes through `set_pitch_bias`: an angle within
			# `pitch_detent_units` of lean of the curve lands on AUTO, which is
			# the curve's own angle. With `pitch_reach_up_far` authored at 0.76
			# the sampled ladder lands inside that detent at t=0.5, and the
			# detent winning there is the ruling, not a rounding error.
			var want := deg
			if absf(cam.pitch_bias_for_deg(deg, t)) <= cam.pitch_detent_units:
				want = cam.pitch_deg_at(t)
			assert_almost_eq(cam.pitch_deg(), want, 0.001, "%f° at t=%f" % [deg, t])
	cam.set_zoom_t(0.5)
	cam.set_pitch_deg(5.0)
	assert_almost_eq(cam.pitch_deg(), cam.pitch_floor_deg_at(0.5), 0.001,
			"below the floor clamps to it")
	cam.set_pitch_deg(89.0)
	assert_almost_eq(cam.pitch_deg(), cam.pitch_ceiling_deg_at(0.5), 0.001,
			"above the ceiling clamps to it")
	cam.set_pitch_deg(cam.pitch_deg_at(0.5))
	assert_true(cam.is_pitch_auto(), "the curve's own angle is AUTO")


func test_reach_narrows_the_band_in_degrees_with_the_zoom() -> void:
	# doc 92 §47's coupling: the data can author less lean far out. The bias
	# range is always [-1, 1] — the ANGLE it buys is what shrinks.
	var cam := _camera()
	cam.pitch_reach_up_near = 1.0
	cam.pitch_reach_up_far = 0.5
	cam.pitch_reach_down_near = 1.0
	cam.pitch_reach_down_far = 1.0
	cam.set_zoom_t(0.0)
	cam.set_pitch_bias(1.0)
	assert_almost_eq(cam.pitch_deg(), 12.0, 0.0001, "close in, the whole band")
	cam.set_zoom_t(1.0)
	assert_almost_eq(cam.reach_up_at(1.0), 0.5, 0.0001)
	assert_almost_eq(cam.pitch_floor_deg_at(1.0), lerpf(62.0, 12.0, 0.5), 0.0001,
			"far out, bias +1 buys half the lean: 37°")
	assert_almost_eq(cam.pitch_deg(), 37.0, 0.0001)
	assert_almost_eq(cam.pitch_ceiling_deg_at(1.0), 78.0, 0.0001,
			"the down reach is authored separately and is still 1.0")
	assert_almost_eq(cam.reach_up_at(0.5), lerpf(1.0, 0.5, 0.5), 0.0001,
			"interpolated by smoothstep, the pitch curve's own shape")


func test_a_tap_above_the_horizon_is_a_typed_miss() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(400.0, 0.0, 400.0))
	cam.set_zoom_t(0.0)
	var top := Vector2(REF_VIEWPORT.x * 0.5, 0.0)
	var bottom := Vector2(REF_VIEWPORT.x * 0.5, REF_VIEWPORT.y)
	# AUTO at Z0: 34° − 20° of half-FOV is 14° of depression at the top of the
	# frame, so every tap hits — the pre-Wave-17 guarantee.
	assert_true(bool(cam.ground_hit(top, REF_VIEWPORT)["hit"]), "AUTO top of frame hits")
	assert_eq(cam.ground_hit(top, REF_VIEWPORT)["reason"], CameraState.GROUND_OK)
	# At the 12° floor the top of the frame is 8° ABOVE the horizon.
	cam.set_pitch_bias(1.0)
	var miss := cam.ground_hit(top, REF_VIEWPORT)
	assert_false(bool(miss["hit"]), "a tap on the sky has no ground under it")
	assert_eq(miss["reason"], CameraState.MISS_ABOVE_HORIZON)
	var guarded: Vector3 = miss["position"]
	assert_almost_eq(guarded.y, 0.0, 0.000001, "the guarded point still lies on y = 0")
	assert_true(is_finite(guarded.x) and is_finite(guarded.z), "…and is finite")
	assert_almost_eq(float(miss["distance"]), cam.distance() * 4.0, 0.001,
			"…at the dist·4 clamp doc 12 §2.16 asks for")
	assert_true(cam.screen_to_ground(top, REF_VIEWPORT).is_equal_approx(guarded),
			"the untyped read keeps the guard's answer, byte for byte")
	assert_true(bool(cam.ground_hit(bottom, REF_VIEWPORT)["hit"]),
			"the bottom of the frame looks 32° down and hits")
	assert_true(bool(cam.ground_hit(Vector2(440.0, 200.0), REF_VIEWPORT)["hit"]),
			"the centre of the frame is 12° down and lands within dist·4")


func test_m_per_dp_is_pitch_invariant_and_the_depth_axis_is_not() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_zoom_t(0.5)
	var flat := cam.m_per_dp(REF_VIEWPORT)
	cam.set_pitch_bias(1.0)
	var floor_deg := cam.pitch_floor_deg_at(0.5)
	assert_almost_eq(cam.m_per_dp(REF_VIEWPORT), flat, 0.000001,
			"screen-right is parallel to the ground at every pitch")
	assert_almost_eq(cam.m_per_dp_depth(REF_VIEWPORT), flat / sin(deg_to_rad(floor_deg)),
			0.0001, "screen-up rakes 1/sin(pitch) further across the ground")
	assert_almost_eq(cam.m_per_dp_anisotropy(), 1.0 / sin(deg_to_rad(floor_deg)), 0.0001)
	cam.clear_pitch_bias()
	cam.set_zoom_t(0.0)
	assert_almost_eq(cam.m_per_dp_anisotropy(), 1.0 / sin(deg_to_rad(34.0)), 0.0001,
			"×1.79 at the curve's own floor")


func test_a_tilt_keeps_the_ground_point_under_the_fingers() -> void:
	# The two-finger tilt re-locks the pan anchor the way a twist does, so the
	# tile under the centroid before the tilt is the tile under it after.
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(400.0, 0.0, 400.0))
	cam.set_zoom_t(0.42)
	cam.yaw = deg_to_rad(45.0)
	var centroid := Vector2(560.0, 260.0)
	var before := cam.screen_to_ground(centroid, REF_VIEWPORT)
	cam.begin_pan(centroid, REF_VIEWPORT)
	cam.begin_tilt()
	for _i in 10:
		cam.apply_tilt(0.06, centroid, REF_VIEWPORT, 1.0 / 60.0)
	assert_false(cam.is_pitch_auto())
	assert_true(cam.pitch_deg() < cam.pitch_deg_at(0.42), "leaned toward the facades")
	var after := cam.screen_to_ground(centroid, REF_VIEWPORT)
	assert_true(after.distance_to(before) < 0.01,
			"same screen point → same ground point across the tilt (%f m)"
			% after.distance_to(before))
	assert_eq(BuildController.tile_at(after), BuildController.tile_at(before),
			"…and therefore the same tile")
	cam.end_tilt()
	cam.end_pan()


func test_a_tilt_at_the_floor_never_throws_the_focus_when_the_anchor_is_sky() -> void:
	var cam := _camera()
	cam.bounds_enabled = false
	cam.set_focus(Vector3(400.0, 0.0, 400.0))
	cam.set_zoom_t(0.0)
	cam.set_pitch_bias(1.0)
	var sky := Vector2(440.0, 0.0)
	assert_false(bool(cam.ground_hit(sky, REF_VIEWPORT)["hit"]))
	var focus := cam.focus
	cam.begin_pan(sky, REF_VIEWPORT)
	cam.update_pan(Vector2(440.0, 40.0), REF_VIEWPORT, 1.0 / 60.0)
	assert_true(cam.focus.distance_to(focus) < 0.000001,
			"a pan anchored on the sky moves nothing rather than a kilometre")
	cam.begin_tilt()
	cam.apply_tilt(-0.2, sky, REF_VIEWPORT, 1.0 / 60.0)
	assert_true(cam.focus.distance_to(focus) < 0.000001, "and neither does a tilt from it")
	cam.end_tilt()
	cam.end_pan()
	# A double tap on the sky zooms without re-anchoring.
	cam.set_pitch_bias(1.0)
	var t_before := cam.zoom_t
	cam.step_zoom(sky, REF_VIEWPORT, -1)
	assert_true(cam.zoom_t > t_before, "still zooms")
	assert_true(cam.focus.distance_to(focus) < 0.000001, "and the focus stays put")


func test_tilt_release_coasts_deterministically_and_stops_in_band() -> void:
	var cam := _camera()
	cam.set_zoom_t(0.5)
	cam.begin_tilt()
	for _i in 6:
		cam.apply_tilt(0.05, Vector2.ZERO, Vector2.ZERO, 1.0 / 60.0)   # 3 units/s
	cam.end_tilt()
	assert_true(cam.is_pitch_coasting(), "a fast flick hands over to the axis momentum")
	var steps := 0
	while cam.is_pitch_coasting() and steps < 600:
		cam.advance(1.0 / 60.0)
		steps += 1
	assert_false(cam.is_pitch_coasting())
	var landed := cam.pitch_bias
	assert_true(landed > 0.3 and landed <= 1.0, "coasted on, inside the band (%f)" % landed)
	# Frame-rate independence: the closed form lands in the same place at 30 Hz.
	var cam2 := _camera()
	cam2.set_zoom_t(0.5)
	cam2.begin_tilt()
	for _i in 6:
		cam2.apply_tilt(0.05, Vector2.ZERO, Vector2.ZERO, 1.0 / 60.0)
	cam2.end_tilt()
	var steps2 := 0
	while cam2.is_pitch_coasting() and steps2 < 600:
		cam2.advance(1.0 / 30.0)
		steps2 += 1
	assert_almost_eq(cam2.pitch_bias, landed, 0.02, "coast is dt-independent")


func test_tilt_past_the_end_rubber_bands_and_springs_back() -> void:
	var cam := _camera()
	cam.set_zoom_t(0.5)
	cam.begin_tilt()
	cam.apply_tilt(1.4)
	assert_true(cam.pitch_bias > 1.0 and cam.pitch_bias < 1.4,
			"past the end the band stretches at pitch_rubber_band (%f)" % cam.pitch_bias)
	assert_almost_eq(cam.pitch_bias, 1.0 + 0.4 * cam.pitch_rubber_band, 0.000001)
	assert_almost_eq(cam.pitch_deg(), cam.pitch_floor_deg_at(0.5), 0.0001,
			"the ANGLE never leaves the band")
	cam.end_tilt()
	var steps := 0
	while (cam.pitch_bias > 1.0 + 0.0005) and steps < 600:
		cam.advance(1.0 / 120.0)
		steps += 1
	assert_almost_eq(cam.pitch_bias, 1.0, 0.001, "critically damped return to the end")
	assert_true(float(steps) / 120.0 < 0.6, "settles in well under a second")


func test_reset_pitch_eases_home_and_cuts_under_reduce_motion() -> void:
	var cam := _camera()
	cam.set_zoom_t(0.3)
	cam.set_pitch_bias(0.8)
	cam.reset_pitch(false)
	assert_true(cam.is_pitch_returning(), "the double action eases")
	assert_false(cam.is_pitch_auto(), "…and is not home yet")
	var steps := 0
	while cam.is_pitch_returning() and steps < 600:
		cam.advance(1.0 / 60.0)
		steps += 1
	assert_true(cam.is_pitch_auto(), "home is AUTO, not a bias of zero")
	assert_true(float(steps) / 60.0 <= cam.pitch_reset_tween_s + 0.05, "over pitch_reset_tween_s")
	cam.set_pitch_bias(-0.6)
	cam.reset_pitch(true)
	assert_true(cam.is_pitch_auto(), "reduce_motion (A8) is a hard cut")
	assert_false(cam.is_pitch_returning())


func test_a_release_inside_the_detent_lands_on_auto() -> void:
	var cam := _camera()
	cam.set_pitch_bias(0.5)
	cam.begin_tilt()
	cam.apply_tilt(-0.48)   # to 0.02, inside pitch_detent_units
	cam.end_tilt()
	assert_true(cam.is_pitch_auto(), "the middle detent is how a player finds AUTO by feel")


func test_save_section_carries_the_pitch_and_validates_the_band() -> void:
	var cam := _camera()
	cam.set_zoom_t(0.42)
	var auto_d := cam.to_dict()
	assert_eq(str(auto_d["pitch_mode"]), "auto", "AUTO is a word, not a zero")
	assert_almost_eq(float(auto_d["pitch_bias"]), 0.0, 0.000001)
	cam.set_pitch_bias(0.6)
	var d := cam.to_dict()
	assert_eq(str(d["pitch_mode"]), "manual")
	assert_almost_eq(float(d["pitch_bias"]), 0.6, 0.000001)
	var restored := _camera()
	restored.from_dict(d)
	assert_false(restored.is_pitch_auto())
	assert_almost_eq(restored.pitch_bias, 0.6, 0.000001)
	assert_almost_eq(restored.pitch_deg(), cam.pitch_deg(), 0.0001, "same angle back")
	# Validation: a save may not resurrect an angle outside the band.
	var wild := _camera()
	wild.from_dict({"zoom_t": 0.42, "yaw_deg": 45.0, "focus_x": 100.0, "focus_z": 100.0,
			"pitch_mode": "manual", "pitch_bias": 5.0})
	assert_almost_eq(wild.pitch_bias, 1.0, 0.000001, "clamped to the band's end")
	assert_almost_eq(wild.pitch_deg(), wild.pitch_floor_deg_at(0.42), 0.0001)
	var nan_save := _camera()
	nan_save.from_dict({"pitch_mode": "manual", "pitch_bias": NAN})
	assert_true(nan_save.is_pitch_auto(), "a non-finite bias reads as AUTO")
	var old := _camera()
	old.set_pitch_bias(0.7)
	old.from_dict({"zoom_t": 0.5, "yaw_deg": 0.0, "focus_x": 10.0, "focus_z": 10.0})
	assert_true(old.is_pitch_auto(), "a pre-Wave-17 save with no pitch keys restores AUTO")
	var ignored := _camera()
	ignored.from_dict({"pitch_mode": "auto", "pitch_bias": 0.9})
	assert_true(ignored.is_pitch_auto(), "a bias under mode auto is ignored")


func test_pitch_axis_tunables_come_from_data() -> void:
	var cfg := _config()
	var block := cfg.camera()
	var cam := _camera(cfg)
	for key: String in ["pitch_manual_min_deg", "pitch_manual_max_deg", "pitch_reach_up_near",
			"pitch_reach_up_far", "pitch_reach_down_near", "pitch_reach_down_far",
			"pitch_rubber_band", "pitch_momentum_decay_k", "pitch_momentum_min_start",
			"pitch_momentum_max", "pitch_momentum_stop", "pitch_spring_omega",
			"pitch_reset_tween_s", "pitch_detent_units", "tilt_dp_per_unit"]:
		assert_true(block.has(key), "data/ui.json.camera carries %s" % key)
		assert_almost_eq(float(cam.get(key)), UIConfig.get_num(block, key, -1.0), 0.000001,
				"%s is read, not hard-coded" % key)
	assert_true(cam.pitch_manual_min_deg < cam.pitch_near_deg,
			"the manual floor is below the curve's own floor, or there is no lean up")
	assert_true(cam.pitch_manual_max_deg > cam.pitch_far_deg,
			"the manual ceiling is above the curve's own ceiling")
	assert_true(cam.pitch_manual_max_deg < 90.0,
			"and never vertical — yaw would stop meaning anything")
	for key: String in ["pitch_reach_up_near", "pitch_reach_up_far",
			"pitch_reach_down_near", "pitch_reach_down_far"]:
		var reach := UIConfig.get_num(block, key, -1.0)
		assert_true(reach > 0.0 and reach <= 1.0, "%s is a fraction of the band" % key)
