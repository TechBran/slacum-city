extends SimTest
## Doc 11 §2.12's vehicle layer, model side: the dead-reckoning / Hermite-blend
## maths in `VehicleMotion`, the triangle budgets on the procedural bodies in
## `VehicleMesh`, and `VehicleView`'s event ingestion.
##
## The motion model is a RefCounted with no clock and no viewport precisely so
## it can be pinned down here rather than judged by eye on a screenshot.

const STEP := 1.0 / 60.0
## Metres per game-minute. 60 m/gm = 1 m per real second at 1x speed, which
## makes every expectation below readable without a calculator.
const SPEED := 60.0


func _seeded(pos := Vector3.ZERO, heading := 0.0, speed := SPEED) -> VehicleMotion:
	var v := VehicleMotion.new(1)
	v.set_state(pos, heading, speed, 1.0)
	return v


func _advance(v: VehicleMotion, seconds: float, gm_per_s := 1.0) -> void:
	var steps := int(round(seconds / STEP))
	for i in steps:
		v.advance(STEP, gm_per_s)


# --------------------------------------------------------- dead reckoning

## Between states the vehicle keeps rolling: no state event for half a second
## must still move it half a second's worth of road.
func test_dead_reckons_along_heading_between_states() -> void:
	var v := _seeded()
	_advance(v, 0.5)
	assert_almost_eq(v.position().x, 30.0, 0.05, "0.5 gm at 60 m/gm = 30 m")
	assert_almost_eq(v.position().z, 0.0, 0.001, "heading 0 stays on the X axis")
	assert_almost_eq(v.heading(), 0.0, 0.001, "heading unchanged with no event")


## Heading 90 deg is +Z: the feed publishes atan2(dz, dx), so the renderer must
## read it the same way round or the whole city drives sideways.
func test_heading_convention_matches_the_feed() -> void:
	var v := _seeded(Vector3.ZERO, PI * 0.5)
	_advance(v, 1.0)
	assert_almost_eq(v.position().z, 60.0, 0.05, "heading PI/2 travels +Z")
	assert_almost_eq(v.position().x, 0.0, 0.05, "…and not +X")


## Sim speed is a multiplier on game-minutes per real second, so 3x moves three
## times as far in the same frame — and PAUSED (0) must not drift at all.
func test_sim_speed_scales_and_pause_freezes() -> void:
	var fast := _seeded()
	_advance(fast, 1.0, 3.0)
	assert_almost_eq(fast.position().x, 180.0, 0.1, "3x covers 3 game-minutes")
	var paused := _seeded()
	_advance(paused, 2.0, 0.0)
	assert_almost_eq(paused.position().x, 0.0, 0.0001, "paused vehicles hold still")


# ---------------------------------------------------------------- blending

## The whole point of the blend: a corner must not tear the picture. Position
## AND velocity are continuous across the state event that turns the car.
func test_corner_is_position_and_velocity_continuous() -> void:
	var v := _seeded()
	_advance(v, 0.25)
	var before_pos := v.position()
	var before_vel := v.velocity()
	# The next state has the car 15 m along, now heading +Z (a right turn).
	v.set_state(Vector3(15.0, 0.0, 0.0), PI * 0.5, SPEED, 1.0)
	assert_true(v.blending(), "a corner starts a blend rather than a snap")
	assert_true(v.position().distance_to(before_pos) < 0.001,
			"position is continuous across the state event")
	assert_true(v.velocity().distance_to(before_vel) < 0.5,
			"velocity is continuous too — that is what Hermite buys over lerp")


## …and once the blend window is over the vehicle is exactly on the sim's
## track, not orbiting near it.
func test_blend_converges_onto_the_authoritative_track() -> void:
	var v := _seeded()
	_advance(v, 0.25)
	v.set_state(Vector3(15.0, 0.0, 0.0), PI * 0.5, SPEED, 1.0)
	# 30 frames at 1/60 s and 1x = exactly half a game-minute past the event,
	# comfortably beyond the 0.28 s blend window.
	for i in 30:
		v.advance(STEP, 1.0)
	assert_false(v.blending(), "the blend window closes")
	var expected := v.track_position(0.5)
	assert_true(v.position().distance_to(expected) < 0.001,
			"on the track: %s vs %s" % [v.position(), expected])
	assert_almost_eq(VehicleMotion.wrap_pi(v.heading() - PI * 0.5), 0.0, 0.001,
			"heading settles on the sim's")


## A respawn or a route reset is not a corner. Doc 11 §2.12: past
## `interp_teleport_threshold_m` the vehicle snaps.
func test_long_jump_snaps_instead_of_flying_across_the_city() -> void:
	var v := _seeded()
	_advance(v, 0.25)
	v.set_state(Vector3(400.0, 0.0, 400.0), 0.0, SPEED, 1.0)
	assert_false(v.blending(), "beyond the teleport threshold there is no blend")
	assert_true(v.position().distance_to(Vector3(400.0, 0.0, 400.0)) < 0.001,
			"the vehicle is where the sim put it")


## Shortest arc: 175 deg to -175 deg is a 10 deg swing through PI, never a
## 350 deg spin through zero.
func test_heading_takes_the_short_way_round() -> void:
	var v := _seeded(Vector3.ZERO, deg_to_rad(175.0))
	_advance(v, 0.25)
	v.set_state(v.position(), deg_to_rad(-175.0), SPEED, 1.0)
	_advance(v, v.blend_s * 0.5)
	var mid := v.heading()
	assert_true(absf(VehicleMotion.wrap_pi(mid - PI)) < deg_to_rad(6.0),
			"mid-blend heading sits near PI, got %f deg" % rad_to_deg(mid))


func test_wrap_pi_normalises_to_the_half_open_turn() -> void:
	assert_almost_eq(VehicleMotion.wrap_pi(TAU + 0.5), 0.5, 0.0001)
	assert_almost_eq(VehicleMotion.wrap_pi(-TAU - 0.5), -0.5, 0.0001)
	assert_almost_eq(VehicleMotion.wrap_pi(3.0 * PI), -PI, 0.0001)


# ----------------------------------------------------------------- Hermite

func test_hermite_hits_its_endpoints_and_tangents() -> void:
	var p0 := Vector3(0.0, 0.0, 0.0)
	var p1 := Vector3(10.0, 0.0, 4.0)
	var m0 := Vector3(6.0, 0.0, 0.0)
	var m1 := Vector3(0.0, 0.0, 6.0)
	assert_true(VehicleMotion.hermite(p0, m0, p1, m1, 0.0).is_equal_approx(p0),
			"t=0 is p0")
	assert_true(VehicleMotion.hermite(p0, m0, p1, m1, 1.0).is_equal_approx(p1),
			"t=1 is p1")
	assert_true(VehicleMotion.hermite_tangent(p0, m0, p1, m1, 0.0)
			.is_equal_approx(m0), "the curve leaves along m0")
	assert_true(VehicleMotion.hermite_tangent(p0, m0, p1, m1, 1.0)
			.is_equal_approx(m1), "…and arrives along m1")


func test_hermite_actually_bends_where_a_lerp_would_cut_the_corner() -> void:
	var p0 := Vector3.ZERO
	var p1 := Vector3(10.0, 0.0, 10.0)
	var m0 := Vector3(20.0, 0.0, 0.0)
	var m1 := Vector3(0.0, 0.0, 20.0)
	var mid := VehicleMotion.hermite(p0, m0, p1, m1, 0.5)
	var straight := p0.lerp(p1, 0.5)
	assert_true(mid.distance_to(straight) > 1.0,
			"the curve swings wide of the chord: %s vs %s" % [mid, straight])
	assert_true(mid.x > mid.z, "…on the side the entry tangent points to")


# -------------------------------------------------------- pose and placement

## Right-hand traffic: the body sits one lane offset to the RIGHT of the
## centreline the sim publishes, and on the road surface, not in it.
func test_transform_offsets_into_the_right_hand_lane() -> void:
	var v := _seeded(Vector3(100.0, 0.0, 100.0), 0.0, 0.0)
	var t := v.transform(0.10, 1.85)
	assert_almost_eq(t.origin.y, 0.10, 0.0001, "lifted to the road surface")
	assert_almost_eq(t.origin.z, 101.85, 0.0001, "heading +X puts right at +Z")
	var back := _seeded(Vector3(100.0, 0.0, 100.0), PI, 0.0)
	assert_almost_eq(back.transform(0.10, 1.85).origin.z, 98.15, 0.0001,
			"oncoming traffic takes the other side of the centreline")


func test_transform_yaw_points_the_nose_down_the_heading() -> void:
	var v := _seeded(Vector3.ZERO, PI * 0.5, 0.0)
	var nose: Vector3 = v.transform(0.0, 0.0).basis * Vector3(1.0, 0.0, 0.0)
	assert_true(nose.is_equal_approx(Vector3(0.0, 0.0, 1.0)),
			"local +X maps onto the heading, got %s" % nose)


func test_fade_runs_in_on_spawn_and_out_on_despawn() -> void:
	var v := _seeded()
	assert_almost_eq(v.fade, 0.0, 0.0001, "a new vehicle starts invisible")
	_advance(v, v.fade_s + 0.05)
	assert_almost_eq(v.fade, 1.0, 0.0001, "…and is fully in after fade_seconds")
	assert_false(v.expired(), "a live vehicle is never expired")
	v.alive = false
	_advance(v, v.fade_s * 0.5)
	assert_true(v.fade > 0.0 and v.fade < 1.0, "despawn fades rather than blinks")
	_advance(v, v.fade_s)
	assert_true(v.expired(), "and is dropped once it has gone")


func test_render_randomness_is_a_pure_hash_of_the_id() -> void:
	assert_eq(VehicleMotion.hash01(41, 7), VehicleMotion.hash01(41, 7),
			"same id and salt, same draw, every run")
	assert_ne(VehicleMotion.hash01(41, 7), VehicleMotion.hash01(42, 7),
			"neighbouring ids do not share a paint")
	for id in range(1, 200):
		var h := VehicleMotion.hash01(id, 91)
		if h < 0.0 or h >= 1.0:
			assert_true(false, "hash01 out of [0,1) for id %d: %f" % [id, h])
			return
	assert_true(true, "hash01 stays inside [0,1)")
