class_name VehicleMotion
extends RefCounted
## Dead reckoning for ONE rendered vehicle (doc 11 §2.12).
##
## The sim publishes a pose per TICK — a tick is 15 game-seconds, so
## `vehicle_state` lands at doc 11 §2.12's 4 Hz at 1× speed and 12 Hz at 3×
## (`sim/roads/traffic_feed.gd` emits from the EVERY_TICK step, doc 06's fleet
## from its own advance). The renderer runs at 60 Hz. Between two states this
## class **extrapolates**: the vehicle keeps rolling along the heading it was
## last given, at the speed it was last given, so motion is continuous at any
## frame rate and at any sim speed — including while the sim is paused, where
## `gm_per_s = 0` freezes every vehicle exactly where it stands.
##
## When the next state lands the new pose is almost never where extrapolation
## put us (the car turned a corner, congestion changed its speed). Snapping
## would strobe, so the two tracks are joined by doc 11 §2.12's **cubic
## Hermite** over `blend_s` seconds: the curve leaves the old rendered pose
## with the old rendered VELOCITY and arrives on the new authoritative track
## with the new one. Position and velocity are both continuous across a state
## event; only acceleration jumps, which no one can see.
##
## Beyond `teleport_m` (doc 11: 40 m) the gap is a respawn or a route reset,
## not a corner — those SNAP, because interpolating them draws a car flying
## across the city.
##
## RefCounted and clock-free on purpose: every number here is a pure function
## of the states pushed in and the deltas advanced, so the whole motion model
## is headless-testable without a viewport (`tests/test_vehicle_motion.gd`).
##
## UNITS, the one thing that bites: sim speeds are **metres per GAME-minute**.
## `advance()` takes real seconds plus `gm_per_s` (game-minutes elapsed per
## real second = the sim speed multiplier, since 1 real second is 1 game-minute
## at 1×). Nothing in this class knows what a wall clock is.

const DEF_BLEND_S := 0.28
const DEF_FADE_S := 0.40
const DEF_TELEPORT_M := 40.0

# ------------------------------------------------------------------ identity

var id: int = 0
var kind: String = "car"                 # car | van | truck (doc 10's feed)
var vehicle_class: String = "civilian"   # civilian | police | fire | medical | …
var mesh_key: String = "car"             # which body the view draws it with
var edge_id: int = -1
var paint: Color = Color.WHITE
## 0..1 lightbar phase offset, so a convoy never strobes in lockstep (§2.12).
var phase: float = 0.0
## The body-tone seed the vehicle shader reads out of INSTANCE_CUSTOM `.r`.
## A pure function of `id`, so it is computed ONCE on spawn rather than
## re-hashed for every vehicle on every frame in `VehicleView._upload` — at the
## Balanced cap that was a hundred-odd `hash01` calls a frame for a number that
## cannot change.
var body_seed: float = 0.0

# -------------------------------------------------------------------- flags

var headlights: bool = false
var siren: bool = false
var lightbar: bool = false
## False once the sim despawned it; the record lives on until `fade` hits 0.
var alive: bool = true
var fade: float = 0.0

# ------------------------------------------------------------------- tuning

var blend_s := DEF_BLEND_S
var fade_s := DEF_FADE_S
var teleport_m := DEF_TELEPORT_M

# -------------------------------------------------------------------- state

var _seeded := false
## Authoritative track: the pose the sim last published, plus the constant
## velocity implied by its heading and speed.
var _a_pos := Vector3.ZERO
var _a_head := 0.0
var _a_speed := 0.0        # metres per game-minute
var _elapsed_gm := 0.0     # game-minutes since that state landed
## Blend source: where the RENDERED vehicle was, and how fast it was going,
## at the instant the state landed.
var _b_pos := Vector3.ZERO
var _b_vel := Vector3.ZERO  # metres per game-minute
var _b_head := 0.0
var _blend_t := 0.0         # real seconds into the blend
var _blend_gm := 0.0        # game-minutes the blend window spans


func _init(p_id: int = 0) -> void:
	id = p_id


# --------------------------------------------------------------- public API

## Push an authoritative pose. `speed` is metres per GAME-minute, `heading`
## radians in XZ with 0 = +X (the convention both feeds publish in).
## `gm_per_s` sizes the blend window in game-time; `snap` forces a hard cut
## (used for the very first pose, and by callers that know it is a teleport).
func set_state(p_pos: Vector3, p_heading: float, p_speed: float,
		gm_per_s: float = 1.0, snap: bool = false) -> void:
	var hard := snap or not _seeded
	if not hard and position().distance_to(p_pos) > teleport_m:
		hard = true
	if hard:
		_b_pos = p_pos
		_b_vel = dir_xz(p_heading) * p_speed
		_b_head = p_heading
		_blend_t = blend_s        # already finished: render straight off the track
	else:
		_b_pos = position()
		_b_vel = velocity()
		_b_head = heading()
		_blend_t = 0.0
	_a_pos = p_pos
	_a_head = p_heading
	_a_speed = p_speed
	_elapsed_gm = 0.0
	_blend_gm = blend_s * maxf(gm_per_s, 0.0)
	_seeded = true


## One rendered frame. `dt_s` real seconds, `gm_per_s` game-minutes per real
## second (0 while paused — everything stands still, nothing drifts).
func advance(dt_s: float, gm_per_s: float = 1.0) -> void:
	if dt_s <= 0.0:
		return
	_elapsed_gm += dt_s * maxf(gm_per_s, 0.0)
	if _blend_t < blend_s:
		_blend_t = minf(_blend_t + dt_s, blend_s)
	var step := dt_s / maxf(fade_s, 0.0001)
	fade = clampf(fade + (step if alive else -step), 0.0, 1.0)


## True once a despawned vehicle has finished fading and may be dropped.
func expired() -> bool:
	return not alive and fade <= 0.0


func blending() -> bool:
	return _blend_t < blend_s


func seeded() -> bool:
	return _seeded


## Where the authoritative track is `gm` game-minutes after the last state.
func track_position(gm: float) -> Vector3:
	return _a_pos + dir_xz(_a_head) * (_a_speed * gm)


## The rendered position: pure extrapolation once the blend is done, doc 11's
## Hermite from the old rendered pose onto the new track while it runs.
func position() -> Vector3:
	if not _seeded:
		return _a_pos
	if _blend_t >= blend_s:
		return track_position(_elapsed_gm)
	var t := _blend_t / blend_s
	return hermite(_b_pos, _b_vel * _blend_gm,
			track_position(_blend_gm), dir_xz(_a_head) * (_a_speed * _blend_gm), t)


## Rendered velocity in metres per game-minute — the tangent of whatever curve
## `position()` is currently on. Feeding this back into the next `set_state`
## is what makes velocity continuous across state events.
func velocity() -> Vector3:
	if not _seeded:
		return Vector3.ZERO
	if _blend_t >= blend_s or _blend_gm <= 0.0:
		return dir_xz(_a_head) * _a_speed
	var t := _blend_t / blend_s
	var tangent := hermite_tangent(_b_pos, _b_vel * _blend_gm,
			track_position(_blend_gm), dir_xz(_a_head) * (_a_speed * _blend_gm), t)
	return tangent / _blend_gm


## Rendered heading, shortest-arc across the blend so a car turning from +175°
## to -175° swings 10° rather than 350°.
func heading() -> float:
	if not _seeded:
		return _a_head
	if _blend_t >= blend_s:
		return _a_head
	return angle_blend(_b_head, _a_head, smooth01(_blend_t / blend_s))


func speed() -> float:
	return _a_speed


## Body transform for the renderer: yaw from the heading, lifted to the road
## surface and pushed `lane_offset` metres to the RIGHT of the centreline so
## opposing traffic passes properly. `scale` carries the spawn/despawn fade.
func transform(road_y: float, lane_offset: float, scale: float = 1.0) -> Transform3D:
	var h := heading()
	var basis := Basis.from_euler(Vector3(0.0, -h, 0.0))
	if scale != 1.0:
		basis = basis.scaled_local(Vector3.ONE * scale)
	var p := position()
	p += right_xz(h) * lane_offset
	p.y = road_y
	return Transform3D(basis, p)


# ------------------------------------------------------------------- maths

## Unit heading vector: 0 rad = +X, growing towards +Z (atan2(dz, dx), which is
## exactly what both sim feeds publish).
static func dir_xz(h: float) -> Vector3:
	return Vector3(cos(h), 0.0, sin(h))


## The right-hand side of `dir_xz(h)` — `forward × up` in Godot's Y-up basis.
static func right_xz(h: float) -> Vector3:
	return Vector3(-sin(h), 0.0, cos(h))


static func wrap_pi(a: float) -> float:
	return fposmod(a + PI, TAU) - PI


static func angle_blend(from_a: float, to_a: float, t: float) -> float:
	return from_a + wrap_pi(to_a - from_a) * clampf(t, 0.0, 1.0)


static func smooth01(t: float) -> float:
	var x := clampf(t, 0.0, 1.0)
	return x * x * (3.0 - 2.0 * x)


## Cubic Hermite (doc 11 §2.12): endpoints `p0`/`p1`, tangents `m0`/`m1`
## expressed per unit of `t` (i.e. already multiplied by the window length).
static func hermite(p0: Vector3, m0: Vector3, p1: Vector3, m1: Vector3,
		t: float) -> Vector3:
	var x := clampf(t, 0.0, 1.0)
	var x2 := x * x
	var x3 := x2 * x
	return p0 * (2.0 * x3 - 3.0 * x2 + 1.0) \
			+ m0 * (x3 - 2.0 * x2 + x) \
			+ p1 * (-2.0 * x3 + 3.0 * x2) \
			+ m1 * (x3 - x2)


## d/dt of `hermite`, in the same per-unit-t units as the tangents.
static func hermite_tangent(p0: Vector3, m0: Vector3, p1: Vector3, m1: Vector3,
		t: float) -> Vector3:
	var x := clampf(t, 0.0, 1.0)
	var x2 := x * x
	return p0 * (6.0 * x2 - 6.0 * x) \
			+ m0 * (3.0 * x2 - 4.0 * x + 1.0) \
			+ p1 * (-6.0 * x2 + 6.0 * x) \
			+ m1 * (3.0 * x2 - 2.0 * x)


## Deterministic per-vehicle jitter — same id, same paint and same lightbar
## phase on every run and after every load. Render-side only (doc 11 §8.1).
static func hash01(vehicle_id: int, salt: int) -> float:
	var h: int = absi((vehicle_id * 73856093) ^ (salt * 19349663)) % 100003
	return float(h) / 100003.0
