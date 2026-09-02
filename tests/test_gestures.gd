extends SimTest
## Doc 12 P1-31: `GestureRecognizer` — the §2.16 state machine driven by synthetic
## touch streams, against the doc's own dp/ms thresholds and its §7 tests 1–4.
## Headless: no `InputEvent`, no viewport, no scene tree.

const VP := Vector2(880.0, 400.0)


func _rec() -> GestureRecognizer:
	return GestureRecognizer.new(UIConfig.load_from_files().gestures())


func _cam() -> CameraState:
	var cfg := UIConfig.load_from_files()
	var cam := CameraState.new(cfg.camera(), cfg.projection_fov_deg(40.0),
			{"tile_meters": 8, "block_tiles": 16, "size_blocks": [7, 7]})
	cam.bounds_enabled = false
	cam.set_focus(Vector3(400.0, 0.0, 400.0))
	return cam


static func _down(index: int, pos: Vector2, time: float) -> Dictionary:
	return {"type": "down", "index": index, "position": pos, "time": time}


static func _move(index: int, pos: Vector2, time: float) -> Dictionary:
	return {"type": "move", "index": index, "position": pos, "time": time}


static func _up(index: int, pos: Vector2, time: float) -> Dictionary:
	return {"type": "up", "index": index, "position": pos, "time": time}


static func _rot(p: Vector2, centre: Vector2, deg: float) -> Vector2:
	return centre + (p - centre).rotated(deg_to_rad(deg))


static func _kinds(events: Array[Dictionary]) -> Array[StringName]:
	var out: Array[StringName] = []
	for e: Dictionary in events:
		out.append(e["kind"])
	return out


static func _first(events: Array[Dictionary], kind: StringName) -> Dictionary:
	for e: Dictionary in events:
		if e["kind"] == kind:
			return e
	return {}


static func _last(events: Array[Dictionary], kind: StringName) -> Dictionary:
	var found: Dictionary = {}
	for e: Dictionary in events:
		if e["kind"] == kind:
			found = e
	return found


## Applies recogniser output to a camera exactly as `TouchRouter` will, so the
## doc's "no jump" assertions are checked against real camera state.
func _drive(cam: CameraState, events: Array[Dictionary]) -> void:
	for e: Dictionary in events:
		match e["kind"]:
			GestureRecognizer.KIND_PAN_BEGIN:
				if cam.is_panning() and bool(e.get("reanchor", false)):
					cam.reanchor_pan(e["position"], VP)
				else:
					cam.begin_pan(e["position"], VP)
			GestureRecognizer.KIND_PAN:
				cam.update_pan(e["position"], VP, 1.0 / 60.0)
			GestureRecognizer.KIND_PAN_END:
				cam.end_pan()
			GestureRecognizer.KIND_TWIST:
				cam.apply_twist(deg_to_rad(float(e["delta_deg"])), e["centroid"], VP)
			GestureRecognizer.KIND_PINCH:
				cam.apply_pinch(float(e["span_prev"]), float(e["span"]), e["centroid"], VP)


# ---------------------------------------------------------------------------
# doc 12 test 1 — tap vs drag
# ---------------------------------------------------------------------------

func test_tap_under_slop_within_tap_window() -> void:
	var g := _rec()
	var out := g.feed_stream([
		_down(0, Vector2(200.0, 200.0), 0.0),
		_move(0, Vector2(206.0, 200.0), 100.0),   # 6 dp travel, under TAP_SLOP 8
		_up(0, Vector2(206.0, 200.0), 180.0),     # 180 ms, under TAP_MAX_MS 220
	])
	assert_true(_kinds(out).has(GestureRecognizer.KIND_TAP), "6 dp in 180 ms -> TAP")
	assert_false(g.saw(&"pan"), "never both a TAP and a PAN")
	assert_eq(g.state, GestureRecognizer.State.IDLE)


func test_drag_over_slop_becomes_pan() -> void:
	var g := _rec()
	var out := g.feed_stream([
		_down(0, Vector2(200.0, 200.0), 0.0),
		_move(0, Vector2(209.0, 200.0), 180.0),   # 9 dp travel, over DRAG_START_SLOP 8
	])
	assert_true(_kinds(out).has(GestureRecognizer.KIND_PAN_BEGIN), "9 dp in 180 ms -> PAN")
	assert_eq(g.state, GestureRecognizer.State.PAN)
	out = g.feed_stream([_up(0, Vector2(209.0, 200.0), 200.0)])
	assert_true(_kinds(out).has(GestureRecognizer.KIND_PAN_END))
	assert_false(g.saw(GestureRecognizer.KIND_TAP), "never both")
	assert_eq(g.state, GestureRecognizer.State.IDLE)


func test_slow_release_inside_slop_is_a_pan_not_a_tap() -> void:
	var g := _rec()
	var out := g.feed_stream([
		_down(0, Vector2(200.0, 200.0), 0.0),
		_move(0, Vector2(206.0, 200.0), 150.0),   # 6 dp: never crosses the drag slop
		_up(0, Vector2(206.0, 200.0), 260.0),     # 260 ms: past TAP_MAX_MS 220
	])
	assert_true(_kinds(out).has(GestureRecognizer.KIND_PAN_BEGIN), "6 dp in 260 ms -> PAN")
	assert_false(_kinds(out).has(GestureRecognizer.KIND_TAP), "never both")


func test_pan_anchors_at_the_finger_down_point() -> void:
	# doc 12 §2.16: "On finger-down, ray-cast the touch to y=0 and store anchor."
	# The 8 dp of slop the recogniser spent deciding is therefore not lost.
	var g := _rec()
	var out := g.feed_stream([
		_down(0, Vector2(300.0, 220.0), 0.0),
		_move(0, Vector2(340.0, 220.0), 60.0),
	])
	var begin := _first(out, GestureRecognizer.KIND_PAN_BEGIN)
	assert_false(begin.is_empty())
	assert_eq(begin["position"], Vector2(300.0, 220.0), "anchor is the down point")
	assert_false(bool(begin["reanchor"]))
	var pan := _first(out, GestureRecognizer.KIND_PAN)
	assert_eq(pan["position"], Vector2(340.0, 220.0), "first pan sample is the moved point")


# ---------------------------------------------------------------------------
# doc 12 test 2 — long press
# ---------------------------------------------------------------------------

func test_long_press_inside_its_slop() -> void:
	var g := _rec()
	var out := g.feed_stream([
		_down(0, Vector2(200.0, 200.0), 0.0),
		_move(0, Vector2(209.0, 200.0), 460.0),   # 9 dp: under LONGPRESS_SLOP 10
	])
	assert_true(_kinds(out).has(GestureRecognizer.KIND_LONG_PRESS),
			"460 ms at 9 dp -> LONG_PRESS")
	assert_false(g.saw(&"pan"), "no pan once the long press is claimed")
	out = g.feed_stream([_up(0, Vector2(209.0, 200.0), 500.0)])
	assert_false(_kinds(out).has(GestureRecognizer.KIND_TAP), "the long press consumed the touch")


func test_long_press_loses_to_the_drag_slop_past_its_own() -> void:
	var g := _rec()
	var out := g.feed_stream([
		_down(0, Vector2(200.0, 200.0), 0.0),
		_move(0, Vector2(211.0, 200.0), 460.0),   # 11 dp: over LONGPRESS_SLOP 10
	])
	assert_false(_kinds(out).has(GestureRecognizer.KIND_LONG_PRESS), "no long press at 11 dp")
	assert_true(_kinds(out).has(GestureRecognizer.KIND_PAN_BEGIN), "-> PAN instead")


func test_long_press_fires_from_the_clock_with_no_move_sample() -> void:
	var g := _rec()
	g.feed(_down(0, Vector2(200.0, 200.0), 0.0))
	assert_true(g.tick(449.0).is_empty(), "not yet at LONGPRESS_MS 450")
	var out := g.tick(450.0)
	assert_true(_kinds(out).has(GestureRecognizer.KIND_LONG_PRESS), "held with no movement")
	assert_true(g.tick(900.0).is_empty(), "fires exactly once")


# ---------------------------------------------------------------------------
# doc 12 test 3 — double tap
# ---------------------------------------------------------------------------

func test_double_tap_inside_window_and_slop() -> void:
	var g := _rec()
	var first := g.feed_stream([
		_down(0, Vector2(100.0, 100.0), 0.0),
		_up(0, Vector2(100.0, 100.0), 100.0),
	])
	assert_true(_kinds(first).has(GestureRecognizer.KIND_TAP))
	var second := g.feed_stream([
		_down(0, Vector2(120.0, 100.0), 250.0),   # 20 dp away, under DOUBLE_TAP_SLOP 24
		_up(0, Vector2(120.0, 100.0), 300.0),     # 200 ms after tap 1, under 260
	])
	assert_true(_kinds(second).has(GestureRecognizer.KIND_DOUBLE_TAP), "200 ms / 20 dp")
	assert_false(_kinds(second).has(GestureRecognizer.KIND_TAP),
			"a double tap zooms; it must not also select")


func test_double_tap_rejected_when_too_slow() -> void:
	var g := _rec()
	g.feed_stream([_down(0, Vector2(100.0, 100.0), 0.0), _up(0, Vector2(100.0, 100.0), 100.0)])
	var second := g.feed_stream([
		_down(0, Vector2(105.0, 100.0), 350.0),
		_up(0, Vector2(105.0, 100.0), 400.0),     # 300 ms after tap 1, over 260
	])
	assert_true(_kinds(second).has(GestureRecognizer.KIND_TAP), "300 ms apart -> two TAPs")
	assert_false(_kinds(second).has(GestureRecognizer.KIND_DOUBLE_TAP))


func test_double_tap_rejected_when_too_far() -> void:
	var g := _rec()
	g.feed_stream([_down(0, Vector2(100.0, 100.0), 0.0), _up(0, Vector2(100.0, 100.0), 100.0)])
	var second := g.feed_stream([
		_down(0, Vector2(130.0, 100.0), 200.0),   # 30 dp away, over DOUBLE_TAP_SLOP 24
		_up(0, Vector2(130.0, 100.0), 250.0),
	])
	assert_true(_kinds(second).has(GestureRecognizer.KIND_TAP), "30 dp apart -> two TAPs")
	assert_false(_kinds(second).has(GestureRecognizer.KIND_DOUBLE_TAP))


# ---------------------------------------------------------------------------
# doc 12 test 4 — multi-touch arbitration
# ---------------------------------------------------------------------------

func test_second_finger_suppresses_the_pending_tap() -> void:
	var g := _rec()
	var out := g.feed_stream([
		_down(0, Vector2(300.0, 200.0), 0.0),
		_down(1, Vector2(500.0, 200.0), 60.0),    # within MULTI_SUPPRESS_MS 80
	])
	var begin := _first(out, GestureRecognizer.KIND_MULTI_BEGIN)
	assert_false(begin.is_empty(), "entered MULTI")
	assert_true(bool(begin["simultaneous"]), "60 ms apart is a simultaneous two-finger down")
	assert_almost_eq(float(begin["span"]), 200.0, 0.0001)
	assert_eq(g.state, GestureRecognizer.State.MULTI)
	out = g.feed_stream([
		_move(0, Vector2(320.0, 200.0), 120.0),
		_up(1, Vector2(500.0, 200.0), 400.0),
		_up(0, Vector2(320.0, 200.0), 420.0),
	])
	assert_false(g.saw(GestureRecognizer.KIND_TAP), "the pending single-finger tap is suppressed")


func test_multi_engages_zoom_and_rotate_concurrently() -> void:
	var g := _rec()
	g.feed_stream([
		_down(0, Vector2(300.0, 200.0), 0.0),
		_down(1, Vector2(500.0, 200.0), 40.0),    # span 200, angle 0
	])
	assert_false(g.is_zoom_engaged())
	assert_false(g.is_twist_engaged())
	# 20 dp of span change is inside the 24 dp deadzone.
	g.feed_stream([_move(1, Vector2(520.0, 200.0), 80.0)])
	assert_false(g.is_zoom_engaged(), "20 dp span change stays inside PINCH_SPAN_SLOP")
	# 30 dp of span change engages ZOOM.
	var out := g.feed_stream([_move(1, Vector2(530.0, 200.0), 120.0)])
	assert_true(g.is_zoom_engaged(), "30 dp span change engages ZOOM")
	assert_true(_kinds(out).has(GestureRecognizer.KIND_PINCH_BEGIN))
	assert_false(g.is_twist_engaged(), "a straight pull is not a twist")
	# Now rotate both fingers 10 degrees about the centroid: ROTATE engages too.
	var centre := (Vector2(300.0, 200.0) + Vector2(530.0, 200.0)) * 0.5
	out = g.feed_stream([
		_move(0, _rot(Vector2(300.0, 200.0), centre, 10.0), 160.0),
		_move(1, _rot(Vector2(530.0, 200.0), centre, 10.0), 161.0),
	])
	assert_true(g.is_twist_engaged(), "10 deg twist engages ROTATE")
	assert_true(g.is_zoom_engaged(), "zoom stays engaged — the two run concurrently")
	assert_true(_kinds(out).has(GestureRecognizer.KIND_PAN), "centroid pan runs always")


func test_lifting_one_finger_returns_to_pan_without_moving_the_camera() -> void:
	var g := _rec()
	var cam := _cam()
	_drive(cam, g.feed_stream([
		_down(0, Vector2(300.0, 200.0), 0.0),
		_down(1, Vector2(500.0, 200.0), 40.0),
	]))
	_drive(cam, g.feed_stream([
		_move(1, Vector2(560.0, 220.0), 120.0),
		_move(0, Vector2(290.0, 190.0), 130.0),
	]))
	assert_eq(g.state, GestureRecognizer.State.MULTI)
	var focus_before := cam.focus
	var zoom_before := cam.zoom_t
	var out := g.feed_stream([_up(1, Vector2(560.0, 220.0), 200.0)])
	_drive(cam, out)
	assert_eq(g.state, GestureRecognizer.State.PAN, "MULTI -> PAN on one finger up")
	var begin := _first(out, GestureRecognizer.KIND_PAN_BEGIN)
	assert_false(begin.is_empty())
	assert_true(bool(begin["reanchor"]), "re-anchored on the remaining finger")
	assert_eq(begin["position"], Vector2(290.0, 190.0), "anchor is the surviving finger")
	assert_true(cam.focus.distance_to(focus_before) < 0.01,
			"|d focus| < 0.01 m on the transition frame")
	assert_almost_eq(cam.zoom_t, zoom_before, 0.000001, "and the zoom does not jump either")
	assert_false(g.is_zoom_engaged(), "sub-gestures disengage with the finger")
	assert_false(g.is_twist_engaged())


# ---------------------------------------------------------------------------
# Pinch and twist extraction
# ---------------------------------------------------------------------------

func test_pinch_scale_extraction() -> void:
	var g := _rec()
	g.feed_stream([
		_down(0, Vector2(300.0, 200.0), 0.0),
		_down(1, Vector2(500.0, 200.0), 30.0),     # span 200 at engage
	])
	var out := g.feed_stream([_move(1, Vector2(540.0, 200.0), 80.0)])  # span 240
	var begin := _first(out, GestureRecognizer.KIND_PINCH_BEGIN)
	assert_false(begin.is_empty(), "40 dp span change crosses the 24 dp deadzone")
	var step := _first(out, GestureRecognizer.KIND_PINCH)
	assert_almost_eq(float(step["scale"]), 1.0, 0.000001,
			"the deadzone is absorbed at engage, not applied as a jump")
	out = g.feed_stream([_move(1, Vector2(780.0, 200.0), 120.0)])       # span 480
	step = _first(out, GestureRecognizer.KIND_PINCH)
	assert_almost_eq(float(step["span"]), 480.0, 0.0001)
	assert_almost_eq(float(step["span_prev"]), 240.0, 0.0001)
	assert_almost_eq(float(step["scale"]), 2.0, 0.000001, "per-frame span_now/span_prev")
	assert_almost_eq(float(step["cumulative_scale"]), 2.4, 0.000001, "480 / 200 from engage")
	# And the camera reading of it: dist scales by span_prev / span_now.
	var cam := _cam()
	cam.set_zoom_t(0.5)
	var d_before := cam.distance()
	cam.begin_pan(step["centroid"], VP)
	cam.apply_pinch(float(step["span_prev"]), float(step["span"]), step["centroid"], VP)
	assert_almost_eq(cam.distance(), d_before * 0.5, 0.001, "spreading the fingers zooms in")


func test_twist_angle_extraction() -> void:
	var g := _rec()
	var p0 := Vector2(300.0, 200.0)
	var p1 := Vector2(500.0, 200.0)
	var centre := (p0 + p1) * 0.5
	g.feed_stream([_down(0, p0, 0.0), _down(1, p1, 30.0)])
	# 10 deg crosses TWIST_DEADZONE 8 and is absorbed at engage.
	var out := g.feed_stream([
		_move(0, _rot(p0, centre, 10.0), 80.0),
		_move(1, _rot(p1, centre, 10.0), 81.0),
	])
	assert_true(g.is_twist_engaged())
	assert_false(g.is_zoom_engaged(), "a pure rotation does not change the span")
	var step := _last(out, GestureRecognizer.KIND_TWIST)
	assert_almost_eq(float(step["cumulative_deg"]), 0.0, 0.0001, "deadzone absorbed")
	# A further 30 deg is reported 1:1.
	out = g.feed_stream([
		_move(0, _rot(p0, centre, 40.0), 140.0),
		_move(1, _rot(p1, centre, 40.0), 141.0),
	])
	step = _last(out, GestureRecognizer.KIND_TWIST)
	assert_almost_eq(float(step["angle_deg"]), 40.0, 0.001, "absolute finger axis angle")
	assert_almost_eq(g.twist_total_deg(), 30.0, 0.001, "30 deg past the deadzone")
	# The camera applies it 1:1 to yaw.
	var cam := _cam()
	cam.rotation_mode = CameraState.RotationMode.FREE
	cam.yaw = 0.0
	cam.apply_twist(deg_to_rad(g.twist_total_deg()))
	assert_almost_eq(rad_to_deg(cam.yaw), 30.0, 0.001)


func test_twist_deadzone_not_crossed() -> void:
	var g := _rec()
	var p0 := Vector2(300.0, 200.0)
	var p1 := Vector2(500.0, 200.0)
	var centre := (p0 + p1) * 0.5
	g.feed_stream([_down(0, p0, 0.0), _down(1, p1, 30.0)])
	g.feed_stream([
		_move(0, _rot(p0, centre, 7.0), 80.0),
		_move(1, _rot(p1, centre, 7.0), 81.0),
	])
	assert_false(g.is_twist_engaged(), "7 deg stays inside TWIST_DEADZONE 8")


func test_two_finger_tap() -> void:
	var g := _rec()
	var out := g.feed_stream([
		_down(0, Vector2(400.0, 200.0), 0.0),
		_down(1, Vector2(500.0, 200.0), 40.0),
		_up(1, Vector2(500.0, 200.0), 120.0),
		_up(0, Vector2(400.0, 200.0), 140.0),
	])
	assert_true(_kinds(out).has(GestureRecognizer.KIND_TWO_FINGER_TAP),
			"two-finger tap -> zoom_t += 0.18")
	assert_false(_kinds(out).has(GestureRecognizer.KIND_TAP))

	var g2 := _rec()
	out = g2.feed_stream([
		_down(0, Vector2(400.0, 200.0), 0.0),
		_down(1, Vector2(500.0, 200.0), 150.0),   # over MULTI_SUPPRESS_MS 80
		_up(1, Vector2(500.0, 200.0), 200.0),
		_up(0, Vector2(400.0, 200.0), 220.0),
	])
	assert_false(_kinds(out).has(GestureRecognizer.KIND_TWO_FINGER_TAP),
			"a sequential second finger is not a two-finger tap")


# ---------------------------------------------------------------------------
# Wiring
# ---------------------------------------------------------------------------

func test_thresholds_are_loaded_from_data_not_hardcoded() -> void:
	var cfg := UIConfig.load_from_files()
	var block := cfg.gestures()
	var g := GestureRecognizer.new(block)
	assert_almost_eq(g.tap_slop_dp, UIConfig.get_num(block, "tap_slop_dp", -1.0), 0.0001)
	assert_almost_eq(g.tap_max_ms, UIConfig.get_num(block, "tap_max_ms", -1.0), 0.0001)
	assert_almost_eq(g.longpress_ms, UIConfig.get_num(block, "longpress_ms", -1.0), 0.0001)
	assert_almost_eq(g.longpress_slop_dp, UIConfig.get_num(block, "longpress_slop_dp", -1.0), 0.0001)
	assert_almost_eq(g.double_tap_ms, UIConfig.get_num(block, "double_tap_ms", -1.0), 0.0001)
	assert_almost_eq(g.double_tap_slop_dp, UIConfig.get_num(block, "double_tap_slop_dp", -1.0), 0.0001)
	assert_almost_eq(g.drag_start_slop_dp, UIConfig.get_num(block, "drag_start_slop_dp", -1.0), 0.0001)
	assert_almost_eq(g.pinch_span_slop_dp, UIConfig.get_num(block, "pinch_span_slop_dp", -1.0), 0.0001)
	assert_almost_eq(g.twist_deadzone_deg, UIConfig.get_num(block, "twist_deadzone_deg", -1.0), 0.0001)
	assert_almost_eq(g.multi_suppress_ms, UIConfig.get_num(block, "multi_suppress_ms", -1.0), 0.0001)
	# doc 12 §2.16's table, as authored.
	assert_almost_eq(g.tap_slop_dp, 8.0, 0.0001)
	assert_almost_eq(g.tap_max_ms, 220.0, 0.0001)
	assert_almost_eq(g.longpress_ms, 450.0, 0.0001)
	assert_almost_eq(g.longpress_slop_dp, 10.0, 0.0001)
	assert_almost_eq(g.double_tap_ms, 260.0, 0.0001)
	assert_almost_eq(g.double_tap_slop_dp, 24.0, 0.0001)
	assert_almost_eq(g.drag_start_slop_dp, 8.0, 0.0001)
	assert_almost_eq(g.pinch_span_slop_dp, 24.0, 0.0001)
	assert_almost_eq(g.twist_deadzone_deg, 8.0, 0.0001)
	assert_almost_eq(g.multi_suppress_ms, 80.0, 0.0001)


func test_pan_drives_the_camera_one_to_one() -> void:
	# End-to-end: a synthetic drag through the recogniser moves the focus by
	# exactly the ground delta between the touch-down and touch-up points.
	var g := _rec()
	var cam := _cam()
	cam.set_zoom_t(0.42)
	cam.yaw = deg_to_rad(45.0)
	var p_down := Vector2(300.0, 240.0)
	var p_up := Vector2(560.0, 150.0)
	var g_down := cam.screen_to_ground(p_down, VP)
	var g_up := cam.screen_to_ground(p_up, VP)
	var before := cam.focus
	_drive(cam, g.feed_stream([_down(0, p_down, 0.0), _move(0, p_up, 60.0)]))
	assert_true((cam.focus - before).distance_to(g_down - g_up) < 0.001,
			"the world tracks the finger 1:1")
	_drive(cam, g.feed_stream([_up(0, p_up, 70.0)]))
	assert_eq(g.state, GestureRecognizer.State.IDLE)


func test_reset_clears_the_machine() -> void:
	var g := _rec()
	g.feed_stream([_down(0, Vector2(100.0, 100.0), 0.0), _move(0, Vector2(140.0, 100.0), 50.0)])
	assert_eq(g.state, GestureRecognizer.State.PAN)
	g.reset()
	assert_eq(g.state, GestureRecognizer.State.IDLE)
	assert_eq(g.finger_count(), 0)
	assert_true(g.recognized.is_empty())


# ---------------------------------------------------------------------------
# Wave 17 — the two-finger TILT, and the table that keeps pinch and twist theirs
# ---------------------------------------------------------------------------

## Feed a two-finger stroke the way a device feeds one: each finger's drag is its
## OWN event, a frame's worth of travel at a time, finger 0 then finger 1.
##
## This helper exists because the coarse alternative lies. Fed as a single 40 dp
## jump per finger, the INTERMEDIATE sample — finger 0 moved, finger 1 not yet —
## is a 11.3° bearing change across a 200 dp span, which engages the (pre-Wave-17)
## TWIST arm before the tilt table is ever consulted. Nothing on a device does
## that: 60 fps at 600 dp/s is a 10 dp step and 2.9°. Every discrimination test
## below therefore walks, and the numbers in its assertions are the settled
## geometry the walk ends on.
func _walk_pair(g: GestureRecognizer, a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2,
		steps: int, t0: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for k in range(1, steps + 1):
		var f := float(k) / float(steps)
		out.append_array(g.feed_stream([
			_move(0, a0.lerp(b0, f), t0 + 30.0 * float(k)),
			_move(1, a1.lerp(b1, f), t0 + 30.0 * float(k) + 1.0)]))
	return out


## The tilt kinds, applied to a camera exactly as `TouchInput` applies them.
func _drive_tilt(cam: CameraState, events: Array[Dictionary]) -> void:
	for e: Dictionary in events:
		match e["kind"]:
			GestureRecognizer.KIND_TILT_BEGIN:
				cam.begin_tilt()
			GestureRecognizer.KIND_TILT:
				cam.apply_tilt(-float(e["delta_dp"]) / cam.tilt_dp_per_unit, e["centroid"], VP,
						1.0 / 60.0)
			GestureRecognizer.KIND_TILT_END:
				cam.end_tilt()
			_:
				_drive(cam, [e])


func test_a_two_finger_vertical_drag_is_a_tilt() -> void:
	var g := _rec()
	var p0 := Vector2(300.0, 200.0)
	var p1 := Vector2(500.0, 200.0)
	g.feed_stream([_down(0, p0, 0.0), _down(1, p1, 30.0)])
	var up20 := Vector2(0.0, -20.0)
	var up30 := Vector2(0.0, -30.0)
	var up40 := Vector2(0.0, -40.0)
	# 20 dp of straight-up travel is inside tilt_engage_dp 24: still a centroid pan.
	var out := _walk_pair(g, p0, p1, p0 + up20, p1 + up20, 2, 60.0)
	assert_false(g.is_tilt_engaged(), "20 dp stays inside TILT_ENGAGE 24")
	assert_true(_kinds(out).has(GestureRecognizer.KIND_PAN), "centroid pan until then")
	# Past 24 dp the TILT engages, with the span and the bearing untouched.
	out = _walk_pair(g, p0 + up20, p1 + up20, p0 + up30, p1 + up30, 1, 150.0)
	assert_true(g.is_tilt_engaged(), "past 24 dp of vertical centroid travel engages TILT")
	assert_true(_kinds(out).has(GestureRecognizer.KIND_TILT_BEGIN))
	assert_false(g.is_zoom_engaged(), "the span did not move: no pinch")
	assert_false(g.is_twist_engaged(), "the bearing did not move: no twist")
	# From here the stroke is the tilt's: a further 10 dp up per finger reports
	# −10 dp of centroid travel and emits NO pan, pinch or twist alongside it.
	out = _walk_pair(g, p0 + up30, p1 + up30, p0 + up40, p1 + up40, 1, 200.0)
	var kinds := _kinds(out)
	assert_true(kinds.has(GestureRecognizer.KIND_TILT))
	assert_false(kinds.has(GestureRecognizer.KIND_PAN), "the tilt takes the stroke")
	assert_false(kinds.has(GestureRecognizer.KIND_PINCH))
	assert_false(kinds.has(GestureRecognizer.KIND_TWIST))
	var moved := 0.0
	for e: Dictionary in out:
		if e["kind"] == GestureRecognizer.KIND_TILT:
			moved += float(e["delta_dp"])
	assert_almost_eq(moved, -10.0, 0.0001, "the batch's two half-samples, summed")
	# The travel it took to DECIDE is absorbed: the engage landed on the sample
	# where the centroid had climbed 25 dp (finger 0 ahead of finger 1 by one
	# frame), and the total is the travel since that point, not since the down.
	assert_almost_eq(g.tilt_total_dp(), -15.0, 0.0001, "the engage travel is absorbed")
	# One finger up ends the tilt BEFORE the hop to PAN.
	out = g.feed_stream([_up(1, p1 + Vector2(0.0, -40.0), 200.0)])
	assert_true(_kinds(out).has(GestureRecognizer.KIND_TILT_END), "tilt_end on the first finger up")
	assert_false(g.is_tilt_engaged())
	assert_eq(g.state, GestureRecognizer.State.PAN, "the survivor is a pan again")
	assert_true(_kinds(out).find(GestureRecognizer.KIND_TILT_END)
			< _kinds(out).find(GestureRecognizer.KIND_PAN_BEGIN), "…in that order")


func test_a_pinch_never_becomes_a_tilt() -> void:
	var g := _rec()
	var p0 := Vector2(300.0, 200.0)
	var p1 := Vector2(500.0, 200.0)
	g.feed_stream([_down(0, p0, 0.0), _down(1, p1, 30.0)])
	g.feed_stream([_move(1, p1 + Vector2(30.0, 0.0), 60.0)])   # span +30: ZOOM
	assert_true(g.is_zoom_engaged())
	var out := g.feed_stream([_move(0, p0 + Vector2(0.0, -60.0), 90.0),
			_move(1, p1 + Vector2(30.0, -60.0), 91.0)])
	assert_false(g.is_tilt_engaged(), "a pinch already in progress is never stolen")
	assert_true(_kinds(out).has(GestureRecognizer.KIND_PINCH), "and it keeps pinching")
	assert_true(_kinds(out).has(GestureRecognizer.KIND_PAN), "with its centroid pan")


func test_a_twist_never_becomes_a_tilt() -> void:
	var g := _rec()
	var p0 := Vector2(300.0, 200.0)
	var p1 := Vector2(500.0, 200.0)
	var centre := (p0 + p1) * 0.5
	g.feed_stream([_down(0, p0, 0.0), _down(1, p1, 30.0)])
	g.feed_stream([_move(0, _rot(p0, centre, 10.0), 60.0), _move(1, _rot(p1, centre, 10.0), 61.0)])
	assert_true(g.is_twist_engaged())
	var lift := Vector2(0.0, -60.0)
	var out := g.feed_stream([_move(0, _rot(p0, centre, 10.0) + lift, 90.0),
			_move(1, _rot(p1, centre, 10.0) + lift, 91.0)])
	assert_false(g.is_tilt_engaged(), "a twist already in progress is never stolen")
	assert_true(_kinds(out).has(GestureRecognizer.KIND_TWIST))


func test_a_stroke_drifting_toward_a_pinch_or_twist_is_refused_as_a_tilt() -> void:
	# Span drift past HALF the pinch slop (12 dp) disqualifies the tilt even
	# though the pinch itself has not engaged yet (24 dp).
	var g := _rec()
	var p0 := Vector2(300.0, 200.0)
	var p1 := Vector2(500.0, 200.0)
	g.feed_stream([_down(0, p0, 0.0), _down(1, p1, 30.0)])
	# Both fingers climb 40 dp while spreading 22: the tilt's engage travel is
	# there, and the span has drifted past its 12 dp half-slop.
	var out := _walk_pair(g, p0, p1, p0 + Vector2(-11.0, -40.0), p1 + Vector2(11.0, -40.0),
			4, 60.0)
	assert_false(g.is_tilt_engaged(), "22 dp of span drift is on its way to a pinch")
	assert_false(g.is_zoom_engaged(), "…and not yet a pinch either")
	assert_true(_kinds(out).has(GestureRecognizer.KIND_PAN), "so it is still the centroid pan")
	# Bearing drift past HALF the twist deadzone (4°) likewise. A SHEAR is what a
	# bearing drift looks like on a horizontal pair: finger 1 climbing 25 dp
	# further than finger 0 across a 200 dp span is 7.1°, inside the corridor
	# between the tilt's 4° refusal (14 dp of shear) and the twist's own 8°
	# engage (28 dp) — the whole width of which is 14 dp, which is why this walks
	# in 5 dp steps and why the numbers below are not round.
	var g2 := _rec()
	g2.feed_stream([_down(0, p0, 0.0), _down(1, p1, 30.0)])
	_walk_pair(g2, p0, p1, p0 + Vector2(0.0, -12.5), p1 + Vector2(0.0, -37.5), 5, 60.0)
	assert_false(g2.is_tilt_engaged(), "6.8° of bearing drift is on its way to a twist")
	assert_false(g2.is_twist_engaged(), "…and not yet a twist either")


func test_a_diagonal_two_finger_drag_stays_a_pan() -> void:
	var g := _rec()
	var p0 := Vector2(300.0, 200.0)
	var p1 := Vector2(500.0, 200.0)
	g.feed_stream([_down(0, p0, 0.0), _down(1, p1, 30.0)])
	var diag := Vector2(40.0, -40.0)
	var out := _walk_pair(g, p0, p1, p0 + diag, p1 + diag, 4, 60.0)
	assert_false(g.is_tilt_engaged(), "|dy| = |dx| is under the 1.5 dominance ratio")
	assert_true(_kinds(out).has(GestureRecognizer.KIND_PAN), "a two-finger drag across the map pans")
	# 60 up, 30 across is 2.0 — a tilt.
	var lean := Vector2(30.0, -60.0)
	out = _walk_pair(g, p0 + diag, p1 + diag, p0 + lean, p1 + lean, 2, 200.0)
	assert_true(g.is_tilt_engaged(), "a mostly-vertical stroke is a tilt")


func test_two_finger_tap_and_lift_leave_no_tilt_behind() -> void:
	var g := _rec()
	var out := g.feed_stream([
		_down(0, Vector2(400.0, 200.0), 0.0), _down(1, Vector2(500.0, 200.0), 40.0),
		_up(1, Vector2(500.0, 200.0), 120.0), _up(0, Vector2(400.0, 200.0), 140.0)])
	assert_true(_kinds(out).has(GestureRecognizer.KIND_TWO_FINGER_TAP), "still a two-finger tap")
	assert_false(_kinds(out).has(GestureRecognizer.KIND_TILT_END), "no tilt was ever live")
	assert_false(g.is_tilt_engaged())


func test_tilt_drives_the_camera_up_the_facades() -> void:
	var g := _rec()
	var cam := _cam()
	cam.set_zoom_t(0.42)
	var p0 := Vector2(300.0, 260.0)
	var p1 := Vector2(500.0, 260.0)
	var curve := cam.pitch_deg()
	_drive_tilt(cam, g.feed_stream([_down(0, p0, 0.0), _down(1, p1, 30.0)]))
	# Straight up 130 dp over five samples: engage, then 100 dp of lean.
	for i in range(1, 6):
		var lift := Vector2(0.0, -26.0 * float(i))
		_drive_tilt(cam, g.feed_stream([_move(0, p0 + lift, 60.0 + 30.0 * i),
				_move(1, p1 + lift, 61.0 + 30.0 * i)]))
	assert_true(cam.is_tilting())
	assert_false(cam.is_pitch_auto())
	assert_true(cam.pitch_deg() < curve, "fingers UP leans the camera toward the facades")
	assert_almost_eq(cam.pitch_bias, (130.0 - 24.0 - 2.0) / cam.tilt_dp_per_unit, 0.02,
			"bias = dp past engage / tilt_dp_per_unit (the engage travel is absorbed)")
	_drive_tilt(cam, g.feed_stream([_up(1, p1 + Vector2(0.0, -130.0), 300.0),
			_up(0, p0 + Vector2(0.0, -130.0), 310.0)]))
	assert_false(cam.is_tilting(), "released")
	assert_false(cam.is_pitch_auto(), "release HOLDS the lean")
	assert_eq(g.state, GestureRecognizer.State.IDLE)


func test_tilt_thresholds_are_loaded_from_data() -> void:
	var block := UIConfig.load_from_files().gestures()
	var g := GestureRecognizer.new(block)
	for key: String in ["tilt_engage_dp", "tilt_span_tolerance_dp",
			"tilt_bearing_tolerance_deg", "tilt_dominance_ratio"]:
		assert_true(block.has(key), "data/ui.json.gestures_dp_ms carries %s" % key)
		assert_almost_eq(float(g.get(key)), UIConfig.get_num(block, key, -1.0), 0.0001)
	# The table's own invariants: the tilt's tolerances are HALF the deadzones
	# they must never steal from, which is what makes the exclusion structural.
	assert_true(g.tilt_span_tolerance_dp <= g.pinch_span_slop_dp * 0.5,
			"span tolerance ≤ half PINCH_SPAN_SLOP")
	assert_true(g.tilt_bearing_tolerance_deg <= g.twist_deadzone_deg * 0.5,
			"bearing tolerance ≤ half TWIST_DEADZONE")
	assert_true(g.tilt_engage_dp > g.tap_slop_dp, "a tilt is never mistaken for a two-finger tap")
	assert_true(g.tilt_dominance_ratio > 1.0, "a diagonal drag is a pan")
