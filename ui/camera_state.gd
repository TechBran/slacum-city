class_name CameraState
extends RefCounted
## The camera interaction model — doc 12 §2.16, headless and Node-free
## (constitution §3: all camera STATE math lives in `RefCounted` classes so it is
## testable without a scene tree).
##
## State is exactly `{focus (y=0), zoom_t ∈ [0,1], yaw, pitch_bias}` (doc 12
## §2.16). Distance, pitch, the camera transform, ground rays and screen
## projection are all derived. That quadruple is the whole handoff to doc 11
## §2.5: the renderer's `CameraRig` reads `{focus, zoom_t, yaw, pitch}` (or the
## ready-made `camera_transform()`) each frame and never reads input.
##
## **The manual pitch axis (Wave 17, doc 98 §43).** `pitch(t)` is still the
## curve, and the curve is still the DEFAULT — but it is now the value the axis
## RESTS on rather than the only value there is. `pitch_bias ∈ [-1, +1]` leans
## the pitch off the curve toward an authored band:
##
##     pitch = lerp(curve(t), target, |bias| · reach(t))
##     target = pitch_manual_min_deg  when bias > 0   (drag UP — look up facades)
##              pitch_manual_max_deg  when bias < 0   (drag DOWN — top-down)
##
## The composition is a **normalised lean toward a floor/ceiling**, not an
## absolute override and not a degree offset, and the reason is the slider's
## middle detent. An absolute override makes the detent a fixed angle that stops
## agreeing with the curve the moment the player zooms; a degree offset makes the
## slider's two ends clip at different zooms (at `t = 0` the curve is 22° off the
## floor and 44° off the ceiling, at `t = 1` it is 50° and 16°). The lean makes
## `bias = 0` mean *exactly* "the curve's own answer" at every zoom, and `±1`
## mean *exactly* "as far as this zoom is allowed to go" — which is the only
## composition where a centred thumb is honest and both ends are reachable.
##
## `reach(t)` is the zoom coupling doc 92 §47 measured: a grazing angle at far
## zoom fills a fragment-bound frustum with skyline, so the allowed lean NARROWS
## as `zoom_t` rises. It is authored per direction, because the cost is not
## symmetric — leaning toward top-down is cheaper than the pose it came from.
##
## **The aim-height ramp (Wave 18, doc 98 §54).** The pitch band alone could not
## do what it was built for, and the reason is that in this rig the camera always
## looks AT THE FOCUS, which is on the ground. The horizon is therefore always
## `pitch` ABOVE the view axis: at the 12° floor with a 40° FOV it sits
## `(1 − tan12°/tan20°)/2 = 20.8 %` down the frame and the ground owns the other
## **79 %** — a floor that is already grazing and still frames two-thirds
## pavement, with the tower tops cropped off the TOP edge. Lowering the floor
## cannot fix it (and cannot move: `18·sin12° = 3.74 m` is what clears doc 11
## §2.6's 3.5 m ground floor). **The aim is the axis that was missing.**
##
##     look_at = focus + (0, aim_height_m(), 0)
##
## `aim_height_m()` is 0 at `bias ≤ 0` — AUTO and the whole top-down half of the
## axis are the camera that shipped, to the bit — and with the UP lean the frame
## recomposes toward leaving the ground exactly `aim_up_ground_frac` of its own
## height. The lean interpolates the view ANGLE and the height is derived out of
## it; `view_pitch_for()` carries that argument and the guard that goes with it.
## The camera POSITION does not move: this is a pure aim lift, so
## every guarantee written against `camera_position()` (the ground-floor
## clearance above, doc 11 §2.5's LOD tiering, doc 92 §47.2's NEAR-boundary
## measurement) survives verbatim, and the only thing that changes is where the
## frustum points. The view axis is allowed to rise ABOVE horizontal —
## `view_pitch_deg()` goes negative — which is the whole point and is what
## `camera_basis()` now carries; `pitch_deg()` remains the ORBIT angle and
## `orbit_basis()` is the rig arm that positions the camera from it.
##
## Ownership split (report 98 C-63): this class owns the **interaction range**
## (`D_MIN`/`D_MAX`, the pitch band, the curves, gestures, momentum, bounds) from
## `data/ui.json.camera`. Doc 11 owns the **projection** (`fov_deg`, `near_m`,
## `far_m`) in `data/render.json`; the vertical FOV is *injected* here because
## ground rays need it, and is never read from `data/ui.json`.
##
## Per-frame ordering inside a two-finger manipulation is twist → zoom →
## anchor-lock, so the anchored ground point stays under the fingers no matter
## which of the three sub-gestures are live (doc 12: "pinch, twist and
## centroid-pan run concurrently").

enum RotationMode { FREE, SNAP45, SNAP90, LOCKED }

## Doc 12 §2.16 quotes doc 11's projection "at the time of writing" as fov 40°.
## It is only a fallback for when `data/render.json` has not been authored yet;
## the real value is always injected from that file.
const FOV_DEG_FALLBACK := 40.0

const WORLD_JSON_PATH := "res://data/world.json"

## `ground_hit()`'s typed answers. A caller branches on `hit`; `reason` is for
## the log line and for the tests, never for control flow that matters.
const GROUND_OK := &"ground"
## The ray leaves the camera going UP (or level). At the pitch floor the top of
## the frustum is above the horizon and a tap up there has no ground under it —
## and since Wave 18's aim ramp that is not a corner of the frame but two thirds
## of it, so every caller that ACTS on the world must branch on `hit`.
const MISS_ABOVE_HORIZON := &"above_horizon"
## The ray points down but so shallowly that the intersection is past
## `dist * 4` — geometrically a hit, practically the far haze.
const MISS_GRAZING := &"grazing"

# --- Interaction range (data/ui.json.camera) --------------------------------
var d_min_m := 18.0
var d_max_m := 420.0
var d_max_city_factor := 1.6
var d_max_city_min_m := 120.0
var pitch_near_deg := 34.0
var pitch_far_deg := 62.0
## The manual band the lean reaches for. `min` is the grazing floor (look UP the
## facades), `max` the top-down ceiling. Both are absolute limits on
## `pitch_deg()`; no bias, save file or gesture can put the camera outside them.
var pitch_manual_min_deg := 12.0
var pitch_manual_max_deg := 78.0
## `reach(t)` — how much of the lean the zoom allows, up and down, near and far.
## Interpolated by `smoothstep(zoom_t)`, the same shape as the pitch curve, so
## the band closes on the same feel the pitch opens on.
var pitch_reach_up_near := 1.0
var pitch_reach_up_far := 1.0
var pitch_reach_down_near := 1.0
var pitch_reach_down_far := 1.0
## The aim-height ramp's authored framing. `aim_up_ground_frac` is the share of
## the FRAME HEIGHT, measured from the bottom edge, that the ground is left at a
## full upward lean — 1/3 is "pavement in the bottom third, sky and facades above
## it". `aim_up_anchor_ndc` is the hard guard: the focus (the pan/zoom/rotate
## anchor) may never sit more than this fraction of the half-frame below the view
## axis, i.e. at 1.0 it may ride the bottom edge and never leave the frame.
var aim_up_ground_frac := 0.3333
var aim_up_anchor_ndc := 1.0
## Gesture feel for the axis, mirroring the pan's: a rubber band past the ends
## while the finger is down, a decaying fling on release, an eased return home.
var pitch_rubber_band := 0.35
var pitch_momentum_decay_k := 9.0
var pitch_momentum_min_start := 0.35   ## bias units / s
var pitch_momentum_max := 4.0          ## bias units / s
var pitch_momentum_stop := 0.05        ## bias units / s
var pitch_spring_omega := 16.0
var pitch_reset_tween_s := 0.3
var pitch_detent_units := 0.04         ## |bias| this small snaps back to AUTO
var tilt_dp_per_unit := 260.0          ## dp of finger travel for a full lean
var tilt_invert := false
var default_zoom_t := 0.42
var default_yaw_deg := 45.0
var bounds_pad_blocks := 2.0
var rubber_band := 0.35
var spring_omega := 12.0
var momentum_min_start_m_s := 3.0
var momentum_max_m_s := 220.0
var momentum_decay_k := 6.0
var momentum_stop_m_s := 0.5
var velocity_ema_alpha := 0.4
var ray_parallel_eps := 0.08
var double_tap_zoom_delta_t := 0.18
var jump_tween_s := 0.45
var jump_arc_threshold_m := 400.0
var jump_arc_tween_s := 0.75
var jump_arc_zoom_bump_t := 0.25
var follow_lerp_k := 8.0
var rotation_snap_deg := 45.0
var rotation_snap_tween_s := 0.25
var rotation_mode: RotationMode = RotationMode.SNAP45

# --- Projection (doc 11, data/render.json) ----------------------------------
var fov_deg := FOV_DEG_FALLBACK

# --- World geometry (constitution §6 via data/world.json) -------------------
var block_m := 128.0
var world_size_m := 896.0  # 7 x 7 land blocks

# --- Live state -------------------------------------------------------------
var focus := Vector3.ZERO
var zoom_t := 0.42
var yaw := 0.0  ## radians
var bounds_enabled := true

## The manual pitch axis. `pitch_auto` true means "nobody has touched it" — the
## curve answers alone and `pitch_bias` is held at 0 so a reader never has to ask
## which of the two is live. Positive bias leans toward the grazing floor.
var pitch_auto := true
var pitch_bias := 0.0

var _pitch_raw := 0.0          ## unbanded bias; `pitch_bias` is its banded view
var _pitch_rubber := false     ## true while tilting or coasting
var _tilting := false
var _pitch_track_v := 0.0
var _pitch_momentum_v := 0.0
var _pitch_momentum_active := false
var _pitch_spring_active := false
var _pitch_spring_v := 0.0
var _pitch_reset_active := false
var _pitch_reset_from := 0.0
var _pitch_reset_elapsed := 0.0

var _raw_focus := Vector3.ZERO  ## unbanded focus; `focus` is its rubber-banded view
var _rubber_active := false     ## true while dragging or coasting

var _panning := false
var _pan_anchor := Vector3.ZERO
## Whether `_pan_anchor` came from a real ground intersection. False only at the
## manual pitch floor, where a finger can go down above the horizon.
var _anchor_valid := true
var _pan_velocity := Vector3.ZERO

var _momentum_v := Vector3.ZERO
var _momentum_active := false

var _spring_active := false
var _spring_v := Vector3.ZERO

var _yaw_snap_active := false
var _yaw_snap_from := 0.0
var _yaw_snap_to := 0.0
var _yaw_snap_elapsed := 0.0

var _jump_active := false
var _jump_elapsed := 0.0
var _jump_dur := 0.0
var _jump_arc := false
var _jump_from := Vector3.ZERO
var _jump_to := Vector3.ZERO
var _jump_t_from := 0.0
var _jump_t_to := 0.0
var _jump_t_peak := 0.0

var _following := false
var _follow_pos := Vector3.ZERO

# Owned-land AABB on the ground plane, as (min_x, min_z) / (max_x, max_z).
var _land_min := Vector2.ZERO
var _land_max := Vector2.ZERO
var _d_max_eff := 420.0


func _init(cam_cfg: Dictionary = {}, projection_fov_deg: float = FOV_DEG_FALLBACK,
		world_cfg: Dictionary = {}) -> void:
	_apply_world(world_cfg)
	_apply_camera_config(cam_cfg)
	fov_deg = projection_fov_deg
	reset()


## Convenience assembler: interaction range from `data/ui.json`, projection from
## doc 11's `data/render.json`, world size from doc 09's `data/world.json`.
static func load_from_files() -> CameraState:
	var cfg := UIConfig.load_from_files()
	var world: Dictionary = {}
	if FileAccess.file_exists(WORLD_JSON_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(WORLD_JSON_PATH))
		if parsed is Dictionary and (parsed as Dictionary).get("world") is Dictionary:
			world = (parsed as Dictionary)["world"]
	return CameraState.new(cfg.camera(), cfg.projection_fov_deg(FOV_DEG_FALLBACK), world)


func _apply_world(world_cfg: Dictionary) -> void:
	if world_cfg.is_empty():
		return
	var tile_m := UIConfig.get_num(world_cfg, "tile_meters", 8.0)
	var block_tiles := UIConfig.get_num(world_cfg, "block_tiles", 16.0)
	block_m = tile_m * block_tiles
	var size: Variant = world_cfg.get("size_blocks", null)
	if size is Array and (size as Array).size() >= 2:
		world_size_m = maxf(float((size as Array)[0]), float((size as Array)[1])) * block_m


func _apply_camera_config(c: Dictionary) -> void:
	if c.is_empty():
		return
	d_min_m = UIConfig.get_num(c, "dist_min_m", d_min_m)
	d_max_m = UIConfig.get_num(c, "dist_max_m", d_max_m)
	d_max_city_factor = UIConfig.get_num(c, "dist_max_city_factor", d_max_city_factor)
	d_max_city_min_m = UIConfig.get_num(c, "dist_max_city_min_m", d_max_city_min_m)
	pitch_near_deg = UIConfig.get_num(c, "pitch_near_deg", pitch_near_deg)
	pitch_far_deg = UIConfig.get_num(c, "pitch_far_deg", pitch_far_deg)
	pitch_manual_min_deg = UIConfig.get_num(c, "pitch_manual_min_deg", pitch_manual_min_deg)
	pitch_manual_max_deg = UIConfig.get_num(c, "pitch_manual_max_deg", pitch_manual_max_deg)
	pitch_reach_up_near = UIConfig.get_num(c, "pitch_reach_up_near", pitch_reach_up_near)
	pitch_reach_up_far = UIConfig.get_num(c, "pitch_reach_up_far", pitch_reach_up_far)
	pitch_reach_down_near = UIConfig.get_num(c, "pitch_reach_down_near", pitch_reach_down_near)
	pitch_reach_down_far = UIConfig.get_num(c, "pitch_reach_down_far", pitch_reach_down_far)
	aim_up_ground_frac = clampf(UIConfig.get_num(c, "aim_up_ground_frac", aim_up_ground_frac),
			0.0, 0.5)
	aim_up_anchor_ndc = clampf(UIConfig.get_num(c, "aim_up_anchor_ndc", aim_up_anchor_ndc),
			0.0, 1.0)
	pitch_rubber_band = UIConfig.get_num(c, "pitch_rubber_band", pitch_rubber_band)
	pitch_momentum_decay_k = UIConfig.get_num(c, "pitch_momentum_decay_k",
			pitch_momentum_decay_k)
	pitch_momentum_min_start = UIConfig.get_num(c, "pitch_momentum_min_start",
			pitch_momentum_min_start)
	pitch_momentum_max = UIConfig.get_num(c, "pitch_momentum_max", pitch_momentum_max)
	pitch_momentum_stop = UIConfig.get_num(c, "pitch_momentum_stop", pitch_momentum_stop)
	pitch_spring_omega = UIConfig.get_num(c, "pitch_spring_omega", pitch_spring_omega)
	pitch_reset_tween_s = UIConfig.get_num(c, "pitch_reset_tween_s", pitch_reset_tween_s)
	pitch_detent_units = UIConfig.get_num(c, "pitch_detent_units", pitch_detent_units)
	tilt_dp_per_unit = maxf(1.0, UIConfig.get_num(c, "tilt_dp_per_unit", tilt_dp_per_unit))
	tilt_invert = bool(c.get("tilt_invert", tilt_invert))
	default_zoom_t = UIConfig.get_num(c, "default_zoom_t", default_zoom_t)
	default_yaw_deg = UIConfig.get_num(c, "default_yaw_deg", default_yaw_deg)
	bounds_pad_blocks = UIConfig.get_num(c, "bounds_pad_blocks", bounds_pad_blocks)
	rubber_band = UIConfig.get_num(c, "rubber_band", rubber_band)
	spring_omega = UIConfig.get_num(c, "spring_omega", spring_omega)
	momentum_min_start_m_s = UIConfig.get_num(c, "momentum_min_start_m_s", momentum_min_start_m_s)
	momentum_max_m_s = UIConfig.get_num(c, "momentum_max_m_s", momentum_max_m_s)
	momentum_decay_k = UIConfig.get_num(c, "momentum_decay_k", momentum_decay_k)
	momentum_stop_m_s = UIConfig.get_num(c, "momentum_stop_m_s", momentum_stop_m_s)
	velocity_ema_alpha = UIConfig.get_num(c, "velocity_ema_alpha", velocity_ema_alpha)
	ray_parallel_eps = UIConfig.get_num(c, "ray_parallel_eps", ray_parallel_eps)
	double_tap_zoom_delta_t = UIConfig.get_num(c, "double_tap_zoom_delta_t", double_tap_zoom_delta_t)
	jump_tween_s = UIConfig.get_num(c, "jump_tween_s", jump_tween_s)
	jump_arc_threshold_m = UIConfig.get_num(c, "jump_arc_threshold_m", jump_arc_threshold_m)
	jump_arc_tween_s = UIConfig.get_num(c, "jump_arc_tween_s", jump_arc_tween_s)
	jump_arc_zoom_bump_t = UIConfig.get_num(c, "jump_arc_zoom_bump_t", jump_arc_zoom_bump_t)
	follow_lerp_k = UIConfig.get_num(c, "follow_lerp_k", follow_lerp_k)
	rotation_snap_deg = UIConfig.get_num(c, "rotation_snap_deg", rotation_snap_deg)
	rotation_snap_tween_s = UIConfig.get_num(c, "rotation_snap_tween_s", rotation_snap_tween_s)
	rotation_mode = CameraState.rotation_mode_from_string(
			str(c.get("rotation_mode_default", "snap45")))


static func rotation_mode_from_string(name: String) -> RotationMode:
	match name:
		"free": return RotationMode.FREE
		"snap90": return RotationMode.SNAP90
		"locked": return RotationMode.LOCKED
		_: return RotationMode.SNAP45


## Fresh camera: default framing, whole world treated as the reachable AABB
## until `set_owned_land_aabb()` narrows it.
func reset() -> void:
	set_owned_land_aabb(Vector2.ZERO, Vector2(world_size_m, world_size_m))
	zoom_t = clampf(default_zoom_t, 0.0, max_zoom_t())
	yaw = deg_to_rad(default_yaw_deg)
	set_focus(Vector3(world_size_m * 0.5, 0.0, world_size_m * 0.5))
	cancel_momentum()
	_spring_active = false
	_yaw_snap_active = false
	_jump_active = false
	_following = false
	clear_pitch_bias()


# ---------------------------------------------------------------------------
# Zoom / pitch curves (doc 12 §2.16)
# ---------------------------------------------------------------------------

## dist(t) = D_MIN * (D_MAX / D_MIN)^t — geometric, so a pinch of a given ratio
## feels the same at every zoom level.
func distance_at(t: float) -> float:
	return d_min_m * pow(d_max_m / d_min_m, clampf(t, 0.0, 1.0))


## Inverse of `distance_at`.
func zoom_t_for_distance(dist: float) -> float:
	var d := maxf(dist, 0.000001)
	return clampf(log(d / d_min_m) / log(d_max_m / d_min_m), 0.0, 1.0)


## pitch(t) = 34° + 28° * smoothstep(0, 1, t).
func pitch_deg_at(t: float) -> float:
	return pitch_near_deg + (pitch_far_deg - pitch_near_deg) \
			* smoothstep(0.0, 1.0, clampf(t, 0.0, 1.0))


func distance() -> float:
	return distance_at(zoom_t)


## The pitch the rig actually uses: the curve, leaned by the manual axis. In AUTO
## this is `pitch_deg_at(zoom_t)` to the last bit — the axis composes, it does not
## replace, so a city that never touches the slider is byte-for-byte the camera
## it was before Wave 17.
func pitch_deg() -> float:
	return pitch_deg_for(zoom_t, 0.0 if pitch_auto else pitch_bias)


## `lerp(curve, target, |bias| · reach)` — see the class doc for why this
## composition and not an override or an offset.
func pitch_deg_for(t: float, bias: float) -> float:
	var curve := pitch_deg_at(t)
	var b := clampf(bias, -1.0, 1.0)
	if is_zero_approx(b):
		return curve
	if b > 0.0:
		return lerpf(curve, pitch_manual_min_deg, b * reach_up_at(t))
	return lerpf(curve, pitch_manual_max_deg, -b * reach_down_at(t))


## How much of the upward (grazing) lean this zoom allows — doc 92 §47's coupling.
func reach_up_at(t: float) -> float:
	return clampf(lerpf(pitch_reach_up_near, pitch_reach_up_far,
			smoothstep(0.0, 1.0, clampf(t, 0.0, 1.0))), 0.0, 1.0)


func reach_down_at(t: float) -> float:
	return clampf(lerpf(pitch_reach_down_near, pitch_reach_down_far,
			smoothstep(0.0, 1.0, clampf(t, 0.0, 1.0))), 0.0, 1.0)


## The shallowest angle reachable at this zoom (bias +1). Equal to
## `pitch_manual_min_deg` wherever `reach_up_at` is 1.
func pitch_floor_deg_at(t: float) -> float:
	return pitch_deg_for(t, 1.0)


func pitch_ceiling_deg_at(t: float) -> float:
	return pitch_deg_for(t, -1.0)


## The bias that puts the pitch at `deg` at zoom `t` — the inverse of
## `pitch_deg_for` for the harness's `--tilt=` and for tests that speak degrees.
## A request outside the reachable band clamps to the nearer end, and a zoom
## whose `reach()` has closed the lean entirely answers 0 (the curve).
func pitch_bias_for_deg(deg: float, t: float) -> float:
	var curve := pitch_deg_at(t)
	if absf(deg - curve) < 0.000001:
		return 0.0
	if deg < curve:
		var span := curve - pitch_floor_deg_at(t)
		return 0.0 if span <= 0.000001 else clampf((curve - deg) / span, 0.0, 1.0)
	var span_down := pitch_ceiling_deg_at(t) - curve
	return 0.0 if span_down <= 0.000001 \
			else -clampf((deg - curve) / span_down, 0.0, 1.0)


## Put the pitch at `deg` for the CURRENT zoom, through `set_pitch_bias` — so the
## middle detent still applies: a degree inside `pitch_detent_units` of the
## curve lands on AUTO rather than on a bias that merely looks like it.
func set_pitch_deg(deg: float) -> void:
	set_pitch_bias(pitch_bias_for_deg(deg, zoom_t))


func pitch_rad() -> float:
	return deg_to_rad(pitch_deg())


func height_m() -> float:
	return distance() * sin(pitch_rad())


# ---------------------------------------------------------------------------
# The aim-height ramp (Wave 18, doc 98 §54) — see the class doc for why
# ---------------------------------------------------------------------------

## Metres the LOOK-AT point rides up the facades above `focus`. Exactly `0.0` at
## `bias ≤ 0`, because `view_pitch_for()` returns the orbit pitch there unchanged
## and this function subtracts them — which is what makes AUTO and the whole
## top-down half of the axis bit-identical to the pre-Wave-18 camera.
func aim_height_m() -> float:
	return aim_height_for(zoom_t, 0.0 if pitch_auto else pitch_bias)


## The look-at height that realises `view_pitch_for(t, bias)`. Pure geometry:
## the camera is `H = D·sin p` up and `R = D·cos p` back, and an axis `v` below
## horizontal through it crosses the focus's vertical at
##
##     aim = H − R·tan v = D·(sin p − cos p·tan v)
##
## which is `0` at `v = p` (the axis already passes through the focus) and grows
## as the axis rises. **The lift is therefore proportional to `R`, not a constant
## number of metres, because the recomposition is ANGULAR** — a fixed height
## would be a 74° pitch-up at Z0 and a rounding error at Z2.
##
## What that comes to, at a full lean (`--tilt=12`), is the ramp's whole scale:
## **5.88 m at Z0, 23.1 m at the 0.42 default, 29.8 m at Z1, 144.0 m at Z2**.
func aim_height_for(t: float, bias: float) -> float:
	var p := deg_to_rad(pitch_deg_for(t, bias))
	var v := view_pitch_for(t, bias)
	if v >= p:
		return 0.0
	return distance_at(t) * (sin(p) - cos(p) * tan(v))


## The world point the camera is aimed at: `focus` plus the ramp. `camera_basis()`
## is the basis whose forward passes through it.
func aim_point() -> Vector3:
	return focus + Vector3(0.0, aim_height_m(), 0.0)


## The angle of the VIEW AXIS below horizontal, in radians — NEGATIVE when the
## ramp has lifted the aim above the camera's own height, which is the camera
## looking up at the sky. This is the frustum's angle and therefore the number
## every projection, every ray and doc 11 §2.5b's cull all read; `pitch_rad()`
## stays the ORBIT angle and is what positions the camera.
func view_pitch_rad() -> float:
	return view_pitch_for(zoom_t, 0.0 if pitch_auto else pitch_bias)


func view_pitch_deg() -> float:
	return rad_to_deg(view_pitch_rad())


## THE RAMP, and the cap that keeps the anchor on screen. The lean interpolates
## the VIEW ANGLE — not the height — from the orbit pitch to an authored target,
## and the height is derived back out of it by `aim_height_for`. Doing it the
## other way round (scale the full-lean height by the lean) is NOT monotone,
## because the orbit pitch is itself falling as the lean rises and takes `R` with
## it: measured, the Z0 aim peaks at 5.896 m around bias 0.95 and comes back down
## to 5.879 m at bias 1, which the slider would show as the horizon nodding.
##
## The target. A camera whose view axis is `v` below horizontal draws the horizon
## at `ndc_y = tan v / tan(fov/2)`. Wanting it `aim_up_ground_frac` of the frame
## above the BOTTOM edge is wanting `ndc_y = 2·frac − 1`, so
##
##     v_target = −atan((1 − 2·frac)·tan(fov/2))    = −6.92° at frac = 1/3
##     v        = lerp(pitch, v_target, |bias|·reach(t))
##
## `v_target` is a constant of the projection and the authored fraction alone, so
## a full lean composes the SAME frame at every zoom — which is the property the
## slider's ends promise. `bias` is scaled by `reach_up_at(t)` exactly as the
## pitch lean is, so the zoom coupling doc 92 §47 bought applies to the aim too
## and the two halves of the axis can never disagree about how far this zoom may
## lean.
##
## THE CAP. The focus is the pan/zoom/twist anchor and `focus_on()`'s landing
## spot, so it may not leave the frame. It sits `p − v` below the axis, so the
## guard is `v ≥ p − atan(aim_up_anchor_ndc·tan(fov/2))`; at the authored 1.0 the
## anchor may ride the bottom edge and no further. It does NOT bind where the
## composition lives — Z0's full lean needs `12° + 6.92° = 18.92°` of drop and
## the frame allows 20° — and it binds by 0.45° at Z1 and 3.5° at Z2, where the
## reach curve has already shortened the lean for the budget's sake.
func view_pitch_for(t: float, bias: float) -> float:
	var p := deg_to_rad(pitch_deg_for(t, bias))
	var lean := clampf(bias, 0.0, 1.0) * reach_up_at(t)
	if lean <= 0.0:
		return p
	var tan_v := _tan_half_v()
	var target := -atan((1.0 - 2.0 * aim_up_ground_frac) * tan_v)
	return maxf(lerpf(p, target, lean), p - atan(aim_up_anchor_ndc * tan_v))


## Distance from the camera to the focus measured ALONG THE VIEW AXIS, which is
## what the perspective divide uses and therefore what sets the on-screen scale
## at the focus. `D` when the ramp is idle; `D·cos(pitch − view_pitch)` once the
## aim has tipped the focus below the axis.
func focus_axis_distance() -> float:
	var drop := pitch_rad() - view_pitch_rad()
	if drop <= 0.0:
		return distance()
	return distance() * cos(drop)


## D_MAX_eff = clamp(city_diagonal_m * 1.6, 120, 420) — keeps a small city from
## floating in an empty void.
func d_max_eff() -> float:
	return _d_max_eff


func max_zoom_t() -> float:
	return zoom_t_for_distance(_d_max_eff)


func set_zoom_t(t: float) -> void:
	zoom_t = clampf(t, 0.0, max_zoom_t())


func set_distance(dist: float) -> void:
	set_zoom_t(zoom_t_for_distance(clampf(dist, d_min_m, _d_max_eff)))


# ---------------------------------------------------------------------------
# Derived rig transform — the struct doc 11 §2.5 consumes
# ---------------------------------------------------------------------------

## The RIG ARM's basis: yaw about +Y, then the ORBIT pitch down about X (Godot's
## YXZ Euler order). This is what places the camera, and it is unchanged by the
## aim-height ramp — which is the whole reason a ramp was chosen over a lower
## floor (see the class doc).
func orbit_basis() -> Basis:
	return Basis.from_euler(Vector3(-pitch_rad(), yaw, 0.0), EULER_ORDER_YXZ)


## Rig basis: yaw about +Y, then the VIEW pitch down about X. Identical to
## `orbit_basis()` to the bit whenever the aim ramp is idle (`view_pitch_rad()`
## returns `pitch_rad()` unchanged, not a reconstruction of it).
func camera_basis() -> Basis:
	return Basis.from_euler(Vector3(-view_pitch_rad(), yaw, 0.0), EULER_ORDER_YXZ)


## Camera3D world position: focus + orbit_basis * (0, 0, D) = focus +
## (D·cos p·sin yaw, D·sin p, D·cos p·cos yaw). Height D·sin p reproduces doc 11
## §2.5's table at every bias, because the ramp moves the aim and not the arm.
func camera_position() -> Vector3:
	return focus + orbit_basis() * Vector3(0.0, 0.0, distance())


## Euler rotation for the Camera3D node (radians, YXZ) — the VIEW angle, the one
## the frustum wears.
func camera_rotation() -> Vector3:
	return Vector3(-view_pitch_rad(), yaw, 0.0)


func camera_transform() -> Transform3D:
	return Transform3D(camera_basis(), camera_position())


## Ground-plane right/forward unit vectors (screen-right and screen-up mapped
## onto y = 0). Used by drawer-aware `focus_on` offsets and by pan fallbacks.
func ground_right() -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


func ground_forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


## Metres of ground per dp at the focus, along the screen-right axis: the frame
## is `2·z·tan(h_half)` metres wide across `viewport_dp.x` dp at view-axis depth
## `z`, and `focus_axis_distance()` is that depth for the focus.
##
## **Invariant under the PITCH BAND, and exact under the AIM RAMP** (Wave 18,
## doc 12 D-85). Screen-right is parallel to the ground at every pitch and is the
## camera's own local X at every yaw, so leaning the pitch band alone does not
## move this number — which is what keeps §2.21's 48 dp tap radius and §2.7's
## drag ghost the same size in metres through a tilt. What the aim ramp changes
## is the DEPTH the focus sits at: tipping the view axis up by `Δ` slides the
## focus `Δ` below it and its axis depth to `D·cos Δ`, so the frame really is
## narrower in metres there and this figure follows it (`×0.946` at the Z0 floor,
## `×0.940` at Z2). It follows it EXACTLY, not approximately — `project_to_screen`
## divides by the same `−local.z`, which is the same `D·cos Δ` — and it moves in
## the conservative direction, fewer metres per dp, so a lifted aim can only make
## a radius pick tighter. The anisotropy is entirely in the other axis;
## `m_per_dp_depth()` is that one, and no caller may use this figure as if it
## covered both.
func m_per_dp(viewport_dp: Vector2) -> float:
	if viewport_dp.x <= 0.0:
		return 0.0
	return (2.0 * focus_axis_distance() * _tan_half_h(viewport_dp)) / viewport_dp.x


## Metres of ground per dp at the focus depth along the screen-UP axis, i.e. into
## the scene. Square pixels make the per-dp angle the same in both axes, so this
## is just the horizontal figure divided by `sin(pitch)`: the same angular step
## rakes further across the ground the shallower the camera looks.
##
##     m_per_dp_depth = m_per_dp / sin(pitch)
##
## At the 34° curve floor that is ×1.79; at the 12° manual floor it is ×4.81. A
## world-space circle of radius `r` therefore projects to an ellipse `2r/m_per_dp`
## dp wide and `2r·sin(pitch)/m_per_dp` dp tall — the tap radius keeps its metres
## and loses screen height as the camera tilts, never the other way round, so a
## tilt can only make the pick MORE conservative.
##
## The divisor stays the ORBIT pitch and not `view_pitch_deg()` under the aim
## ramp, because the foreshortening asked about here is the angle the line of
## sight *to the focus* makes with the ground, and that line is the rig arm — the
## ramp swings the frame around it, not it.
func m_per_dp_depth(viewport_dp: Vector2) -> float:
	var s := sin(pitch_rad())
	if s <= 0.000001:
		return 0.0
	return m_per_dp(viewport_dp) / s


## `m_per_dp_depth / m_per_dp` = `1 / sin(pitch)`. The one number that says how
## far from round a screen-space radius has become.
func m_per_dp_anisotropy() -> float:
	var s := sin(pitch_rad())
	return 0.0 if s <= 0.000001 else 1.0 / s


func _tan_half_v() -> float:
	return tan(deg_to_rad(fov_deg) * 0.5)


func _tan_half_h(viewport_dp: Vector2) -> float:
	var aspect := 1.0 if viewport_dp.y <= 0.0 else viewport_dp.x / viewport_dp.y
	return _tan_half_v() * aspect


# ---------------------------------------------------------------------------
# Ray casting and projection (both needed for the exact 1:1 ground lock)
# ---------------------------------------------------------------------------

## World-space ray for a dp screen point, origin top-left.
func screen_ray(screen_dp: Vector2, viewport_dp: Vector2) -> Dictionary:
	var w := maxf(viewport_dp.x, 1.0)
	var h := maxf(viewport_dp.y, 1.0)
	var ndc_x := (screen_dp.x / w) * 2.0 - 1.0
	var ndc_y := 1.0 - (screen_dp.y / h) * 2.0
	var tv := _tan_half_v()
	var local := Vector3(ndc_x * tv * (w / h), ndc_y * tv, -1.0)
	return {"origin": camera_position(), "direction": (camera_basis() * local).normalized()}


## Ray-cast a touch point to the ground plane y = 0, **typed**. Returns
##     {hit: bool, position: Vector3, reason: StringName, distance: float}
## `reason` is `GROUND_OK`, `MISS_ABOVE_HORIZON` or `MISS_GRAZING`.
##
## Wave 17 made this the honest signature. Doc 12 §2.16's guard — clamp a
## near-parallel ray to `dist * 4` rather than let it shoot to infinity — is
## still applied and `position` still carries the clamped point, because pan and
## pinch want *a* point and the old behaviour is exactly right for them. What
## changed is that a caller which must not act on a guess can now ask: at the
## manual pitch floor the top of the frustum is above the horizon, and a tap up
## there has no tile under it at any distance.
func ground_hit(screen_dp: Vector2, viewport_dp: Vector2) -> Dictionary:
	var ray := screen_ray(screen_dp, viewport_dp)
	var origin: Vector3 = ray["origin"]
	var dir: Vector3 = ray["direction"]
	var max_t := distance() * 4.0
	var t := max_t
	var hit := true
	var reason := GROUND_OK
	if dir.y >= -ray_parallel_eps:
		hit = false
		reason = MISS_ABOVE_HORIZON if dir.y >= 0.0 else MISS_GRAZING
	else:
		var exact := -origin.y / dir.y
		if exact > max_t:
			hit = false
			reason = MISS_GRAZING
		else:
			t = exact
	var point := origin + dir * t
	point.y = 0.0
	return {"hit": hit, "position": point, "reason": reason, "distance": t}


## The untyped read, kept verbatim for the callers that want the guard's answer
## whether or not it was a real intersection (pan, pinch, the anchor lock). Every
## byte of its behaviour predates Wave 17.
func screen_to_ground(screen_dp: Vector2, viewport_dp: Vector2) -> Vector3:
	return ground_hit(screen_dp, viewport_dp)["position"]


## Forward projection of a world point to dp screen space (the inverse of
## `screen_to_ground` for ground points). `behind` is true when the point is at
## or behind the camera plane, in which case the returned point is meaningless.
func project_to_screen(world: Vector3, viewport_dp: Vector2) -> Dictionary:
	var w := maxf(viewport_dp.x, 1.0)
	var h := maxf(viewport_dp.y, 1.0)
	var local := camera_basis().inverse() * (world - camera_position())
	if local.z >= -0.000001:
		return {"position": Vector2.ZERO, "behind": true}
	var tv := _tan_half_v()
	var ndc_x := (local.x / -local.z) / (tv * (w / h))
	var ndc_y := (local.y / -local.z) / tv
	return {
		"position": Vector2((ndc_x + 1.0) * 0.5 * w, (1.0 - ndc_y) * 0.5 * h),
		"behind": false,
	}


# ---------------------------------------------------------------------------
# Focus, bounds and the rubber band
# ---------------------------------------------------------------------------

func set_focus(p: Vector3) -> void:
	_raw_focus = Vector3(p.x, 0.0, p.z)
	if bounds_enabled and not _rubber_active:
		_raw_focus = clamp_focus(_raw_focus)
	_sync_focus()


## Owned-land AABB drives both the pan bounds (padded by `bounds_pad_blocks`)
## and `D_MAX_eff` (from the city diagonal).
func set_owned_land_aabb(min_xz: Vector2, max_xz: Vector2) -> void:
	_land_min = Vector2(minf(min_xz.x, max_xz.x), minf(min_xz.y, max_xz.y))
	_land_max = Vector2(maxf(min_xz.x, max_xz.x), maxf(min_xz.y, max_xz.y))
	var diagonal := (_land_max - _land_min).length()
	_d_max_eff = clampf(diagonal * d_max_city_factor, d_max_city_min_m, d_max_m)
	set_zoom_t(zoom_t)


func bounds_min() -> Vector2:
	return _land_min - Vector2.ONE * (bounds_pad_blocks * block_m)


func bounds_max() -> Vector2:
	return _land_max + Vector2.ONE * (bounds_pad_blocks * block_m)


func clamp_focus(p: Vector3) -> Vector3:
	if not bounds_enabled:
		return p
	var lo := bounds_min()
	var hi := bounds_max()
	return Vector3(clampf(p.x, lo.x, hi.x), 0.0, clampf(p.z, lo.y, hi.y))


func is_out_of_bounds() -> bool:
	return bounds_enabled and focus.distance_squared_to(clamp_focus(focus)) > 0.0000001


func _band(p: Vector3) -> Vector3:
	if not bounds_enabled:
		return p
	var c := clamp_focus(p)
	return c + (p - c) * rubber_band


func _sync_focus() -> void:
	focus = _band(_raw_focus) if _rubber_active else _raw_focus


func _translate_focus(delta: Vector3) -> void:
	_raw_focus += Vector3(delta.x, 0.0, delta.z)
	_sync_focus()


## Move the focus by an exact ground-plane displacement. In bounds this is
## literally 1:1 — N metres of ground move the focus N metres.
func pan_by_ground_delta(delta: Vector3) -> void:
	_translate_focus(delta)


# ---------------------------------------------------------------------------
# Pan — exact 1:1 world lock
# ---------------------------------------------------------------------------

## Ray-cast the touch to y = 0 and remember it; the anchor stays glued under the
## finger until `end_pan()`. Any new touch cancels momentum immediately.
func begin_pan(screen_dp: Vector2, viewport_dp: Vector2) -> void:
	cancel_momentum()
	_spring_active = false
	_following = false
	_panning = true
	_rubber_active = true
	_pan_velocity = Vector3.ZERO
	_raw_focus = focus
	_set_anchor(screen_dp, viewport_dp)


## Re-anchor without moving the camera (MULTI → PAN when one finger lifts:
## "re-anchor to the remaining finger, no jump").
func reanchor_pan(screen_dp: Vector2, viewport_dp: Vector2) -> void:
	_set_anchor(screen_dp, viewport_dp)


func _set_anchor(screen_dp: Vector2, viewport_dp: Vector2) -> void:
	var answer := ground_hit(screen_dp, viewport_dp)
	_pan_anchor = answer["position"]
	_anchor_valid = bool(answer["hit"])


## `focus += anchor − ray_to_ground(touch)`. Because translating the focus
## translates the ground hit by exactly the same vector, this converges in one
## step and is exact, at any zoom, pitch or yaw.
func update_pan(screen_dp: Vector2, viewport_dp: Vector2, dt: float = 0.0) -> void:
	var before := focus
	_lock_anchor(screen_dp, viewport_dp)
	if dt > 0.0:
		var instantaneous := (focus - before) / dt
		_pan_velocity = _pan_velocity * (1.0 - velocity_ema_alpha) \
				+ instantaneous * velocity_ema_alpha


## The 1:1 lock, guarded at both ends. Above the pitch curve's own floor both
## rays always hit (34° − 20° of half-FOV is 14° of depression, well past the
## 4.6° `ray_parallel_eps` horizon), so this guard is unreachable for every pose
## that existed before the manual axis — and at the manual floor it is the
## difference between "the world stops tracking the finger" and "the focus is
## thrown a kilometre because a ray was clamped".
func _lock_anchor(screen_dp: Vector2, viewport_dp: Vector2) -> void:
	if not _anchor_valid:
		return
	var answer := ground_hit(screen_dp, viewport_dp)
	if not bool(answer["hit"]):
		return
	_translate_focus(_pan_anchor - (answer["position"] as Vector3))


## Release: hand the tracked velocity to momentum, or start the rubber-band
## spring when the focus is outside the padded AABB.
func end_pan() -> void:
	_panning = false
	if is_out_of_bounds():
		_start_spring()
		_pan_velocity = Vector3.ZERO
		return
	_rubber_active = false
	_raw_focus = focus
	if _pan_velocity.length() >= momentum_min_start_m_s:
		_momentum_v = _pan_velocity.limit_length(momentum_max_m_s)
		_momentum_active = true
		_rubber_active = true
	else:
		_momentum_v = Vector3.ZERO
		_momentum_active = false
	_pan_velocity = Vector3.ZERO
	_sync_focus()


## Start a fling directly (used by `TouchRouter` when it owns the velocity, and
## by the momentum tests). Returns false when the velocity is under the
## `momentum_min_start_m_s` floor.
func start_momentum(velocity: Vector3) -> bool:
	if velocity.length() < momentum_min_start_m_s:
		_momentum_v = Vector3.ZERO
		_momentum_active = false
		return false
	_raw_focus = focus
	_momentum_v = Vector3(velocity.x, 0.0, velocity.z).limit_length(momentum_max_m_s)
	_momentum_active = true
	_rubber_active = true
	return true


func is_panning() -> bool:
	return _panning


func pan_velocity() -> Vector3:
	return _pan_velocity


func momentum_velocity() -> Vector3:
	return _momentum_v


func is_coasting() -> bool:
	return _momentum_active


func cancel_momentum() -> void:
	_momentum_active = false
	_momentum_v = Vector3.ZERO
	if not _panning:
		_rubber_active = false
		_raw_focus = focus


# ---------------------------------------------------------------------------
# Zoom about a gesture point
# ---------------------------------------------------------------------------

## Self-contained "zoom about this screen point": used by double-tap and by
## `focus_on`. The ground point under `screen_dp` is invariant.
func zoom_about_point(screen_dp: Vector2, viewport_dp: Vector2, new_t: float) -> void:
	var before := ground_hit(screen_dp, viewport_dp)
	set_zoom_t(new_t)
	var after := ground_hit(screen_dp, viewport_dp)
	# A double tap on the sky zooms without re-anchoring rather than dragging the
	# focus to a clamped point that was never a place.
	if not bool(before["hit"]) or not bool(after["hit"]):
		return
	_translate_focus((before["position"] as Vector3) - (after["position"] as Vector3))


## Pinch step (doc 12 §2.16): `dist = clamp(dist * (span_prev/span_now), D_MIN,
## D_MAX_eff)`, then re-anchor the *engage-time* ground point to the centroid's
## current screen position. Call `begin_pan(centroid)` at engage first; the
## anchor is shared with centroid-pan, which is what makes pinch + pan + twist
## compose into full RST manipulation.
func apply_pinch(span_prev: float, span_now: float,
		centroid_dp: Vector2, viewport_dp: Vector2) -> void:
	if span_now <= 0.0 or span_prev <= 0.0:
		return
	set_distance(distance() * (span_prev / span_now))
	_lock_anchor(centroid_dp, viewport_dp)


## Double-tap zooms in by `double_tap_zoom_delta_t`, two-finger tap zooms out.
func step_zoom(screen_dp: Vector2, viewport_dp: Vector2, direction: int) -> void:
	zoom_about_point(screen_dp, viewport_dp,
			zoom_t - float(direction) * double_tap_zoom_delta_t)


# ---------------------------------------------------------------------------
# Yaw — twist and snap
# ---------------------------------------------------------------------------

## 1:1 with the fingers. `locked` ignores twist entirely and returns false so the
## caller can raise the "Rotation locked" toast on first attempt.
func apply_twist(delta_rad: float, centroid_dp := Vector2.ZERO,
		viewport_dp := Vector2.ZERO) -> bool:
	if rotation_mode == RotationMode.LOCKED:
		return false
	_yaw_snap_active = false
	yaw = wrapf(yaw + delta_rad, -PI, PI)
	if viewport_dp.x > 0.0 and _panning:
		_lock_anchor(centroid_dp, viewport_dp)
	return true


func snap_step_deg() -> float:
	match rotation_mode:
		RotationMode.SNAP45: return rotation_snap_deg
		RotationMode.SNAP90: return 90.0
		_: return 0.0


## Nearest snap target for the current yaw, in degrees (unwrapped, so the tween
## always takes the short way round).
func yaw_snap_target_deg() -> float:
	var step := snap_step_deg()
	if step <= 0.0:
		return rad_to_deg(yaw)
	return roundf(rad_to_deg(yaw) / step) * step


## On release: tween to the nearest snap over `rotation_snap_tween_s` with
## ease_out_back(0.8). `free` leaves the yaw alone, `locked` never got here.
func release_twist() -> bool:
	if rotation_mode == RotationMode.FREE or rotation_mode == RotationMode.LOCKED:
		return false
	_yaw_snap_from = rad_to_deg(yaw)
	_yaw_snap_to = yaw_snap_target_deg()
	if is_equal_approx(_yaw_snap_from, _yaw_snap_to):
		return false
	_yaw_snap_elapsed = 0.0
	_yaw_snap_active = true
	return true


func is_snapping_yaw() -> bool:
	return _yaw_snap_active


static func ease_out_back(x: float, overshoot: float = 0.8) -> float:
	var u := x - 1.0
	return u * u * ((overshoot + 1.0) * u + overshoot) + 1.0


# ---------------------------------------------------------------------------
# Pitch — the manual axis (Wave 17, doc 98 §43)
# ---------------------------------------------------------------------------

## Back to AUTO with no tween, and every transient on the axis dropped. This is
## `reset()`'s call and the loader's, not the double-tap's — that one eases.
func clear_pitch_bias() -> void:
	pitch_auto = true
	pitch_bias = 0.0
	_pitch_raw = 0.0
	_pitch_rubber = false
	_tilting = false
	_pitch_track_v = 0.0
	_pitch_momentum_v = 0.0
	_pitch_momentum_active = false
	_pitch_spring_active = false
	_pitch_spring_v = 0.0
	_pitch_reset_active = false


## Put the axis at an exact bias. `|bias| ≤ pitch_detent_units` is the middle
## detent and lands on AUTO rather than on a bias that merely looks like it —
## the detent is what makes the slider's middle *mean* something.
func set_pitch_bias(bias: float) -> void:
	_pitch_reset_active = false
	_pitch_momentum_active = false
	_pitch_spring_active = false
	var b := clampf(bias, -1.0, 1.0)
	if absf(b) <= pitch_detent_units:
		pitch_auto = true
		pitch_bias = 0.0
		_pitch_raw = 0.0
		return
	pitch_auto = false
	_pitch_raw = b
	_sync_pitch()


func is_pitch_auto() -> bool:
	return pitch_auto


func is_tilting() -> bool:
	return _tilting


func is_pitch_coasting() -> bool:
	return _pitch_momentum_active


func is_pitch_returning() -> bool:
	return _pitch_reset_active


## Finger down on the axis (slider thumb or the two-finger drag). Kills whatever
## the axis was doing so the grab is exact, and turns the rubber band on.
func begin_tilt() -> void:
	_pitch_reset_active = false
	_pitch_momentum_active = false
	_pitch_spring_active = false
	_pitch_momentum_v = 0.0
	_pitch_track_v = 0.0
	_tilting = true
	_pitch_rubber = true
	pitch_auto = false
	_pitch_raw = pitch_bias


## One step of the drag, in **bias units** (`dp / tilt_dp_per_unit` upstream).
## `centroid_dp` re-locks the pan anchor exactly the way `apply_twist` does, so
## the ground point under the fingers survives the tilt — but only when the
## anchor is real, which at the pitch floor it may not be (see `_lock_anchor`).
func apply_tilt(delta_units: float, centroid_dp := Vector2.ZERO,
		viewport_dp := Vector2.ZERO, dt: float = 0.0) -> void:
	if not _tilting:
		begin_tilt()
	var before := pitch_bias
	_pitch_raw = clampf(_pitch_raw + delta_units, -2.0, 2.0)
	_sync_pitch()
	if dt > 0.0:
		var instantaneous := (pitch_bias - before) / dt
		_pitch_track_v = _pitch_track_v * (1.0 - velocity_ema_alpha) \
				+ instantaneous * velocity_ema_alpha
	if viewport_dp.x > 0.0 and _panning:
		_lock_anchor(centroid_dp, viewport_dp)


## Release. Hands the tracked velocity to the axis momentum, or springs back into
## range when the band was stretched past an end; a release inside the detent
## lands on AUTO, which is how a player finds the middle without aiming for it.
func end_tilt() -> void:
	_tilting = false
	var clamped := _clamp_bias(_pitch_raw)
	if absf(_pitch_raw - clamped) > 0.000001:
		_pitch_raw = pitch_bias
		_pitch_spring_v = 0.0
		_pitch_spring_active = true
		_pitch_track_v = 0.0
		return
	_pitch_rubber = false
	_pitch_raw = pitch_bias
	if absf(pitch_bias) <= pitch_detent_units and absf(_pitch_track_v) < pitch_momentum_min_start:
		clear_pitch_bias()
		return
	if absf(_pitch_track_v) >= pitch_momentum_min_start:
		_pitch_momentum_v = clampf(_pitch_track_v, -pitch_momentum_max, pitch_momentum_max)
		_pitch_momentum_active = true
		_pitch_rubber = true
	else:
		_pitch_momentum_v = 0.0
	_pitch_track_v = 0.0


## The double-action: snap home to AUTO with an ease. `reduce_motion` (A8) cuts
## instead of easing, like every other tween in this file.
func reset_pitch(reduce_motion: bool = false) -> void:
	_tilting = false
	_pitch_momentum_active = false
	_pitch_spring_active = false
	_pitch_momentum_v = 0.0
	_pitch_track_v = 0.0
	if reduce_motion or pitch_auto or is_zero_approx(pitch_bias) \
			or pitch_reset_tween_s <= 0.0:
		clear_pitch_bias()
		return
	_pitch_reset_from = pitch_bias
	_pitch_reset_elapsed = 0.0
	_pitch_reset_active = true
	_pitch_rubber = false


## The reachable bias range at this zoom is always the full [-1, 1]; the band
## `reach()` closes is in DEGREES, not in slider travel, so the thumb keeps its
## whole column and the *angle* it buys shrinks. `_clamp_bias` therefore only
## enforces the ends.
func _clamp_bias(b: float) -> float:
	return clampf(b, -1.0, 1.0)


func _sync_pitch() -> void:
	var clamped := _clamp_bias(_pitch_raw)
	pitch_bias = clamped + (_pitch_raw - clamped) * pitch_rubber_band \
			if _pitch_rubber else clamped
	if not _pitch_rubber:
		_pitch_raw = pitch_bias


func _advance_pitch(dt: float) -> void:
	if _pitch_reset_active:
		_pitch_reset_elapsed += dt
		var x := 1.0 if pitch_reset_tween_s <= 0.0 \
				else clampf(_pitch_reset_elapsed / pitch_reset_tween_s, 0.0, 1.0)
		pitch_bias = _pitch_reset_from * (1.0 - CameraState._ease_out_cubic(x))
		_pitch_raw = pitch_bias
		if x >= 1.0:
			clear_pitch_bias()
		return
	if _pitch_momentum_active:
		# Same closed form as the pan's fling: Δx = v·(1 − e^{−K·dt}) / K, exact
		# and identical at any frame rate.
		var decay := exp(-pitch_momentum_decay_k * dt)
		_pitch_raw += _pitch_momentum_v * ((1.0 - decay) / pitch_momentum_decay_k)
		_pitch_momentum_v *= decay
		_sync_pitch()
		var out_of_band := absf(_pitch_raw - _clamp_bias(_pitch_raw)) > 0.000001
		if absf(_pitch_momentum_v) < pitch_momentum_stop or out_of_band:
			_pitch_momentum_active = false
			_pitch_momentum_v = 0.0
			if out_of_band:
				_pitch_raw = pitch_bias
				_pitch_spring_v = 0.0
				_pitch_spring_active = true
			else:
				_pitch_rubber = false
				_pitch_raw = pitch_bias
				if absf(pitch_bias) <= pitch_detent_units:
					clear_pitch_bias()
		return
	if _pitch_spring_active:
		# Critically damped, closed form — `_advance_spring`'s scalar twin.
		var target := _clamp_bias(pitch_bias)
		var a := pitch_bias - target
		var b := _pitch_spring_v + a * pitch_spring_omega
		var decay := exp(-pitch_spring_omega * dt)
		var x := (a + b * dt) * decay
		_pitch_spring_v = (b - (a + b * dt) * pitch_spring_omega) * decay
		pitch_bias = target + x
		_pitch_raw = pitch_bias
		if absf(pitch_bias - target) < 0.0005 and absf(_pitch_spring_v) < 0.005:
			pitch_bias = target
			_pitch_raw = target
			_pitch_spring_v = 0.0
			_pitch_spring_active = false
			_pitch_rubber = false
			if absf(pitch_bias) <= pitch_detent_units:
				clear_pitch_bias()


# ---------------------------------------------------------------------------
# Camera jumps and follow
# ---------------------------------------------------------------------------

## `focus_on(pos, dist_target)` — short hops tween straight, long hops arc out
## and back in. `reduce_motion` (A8) cuts instead of arcing.
func focus_on(pos: Vector3, dist_target: float = -1.0, reduce_motion: bool = false) -> void:
	cancel_momentum()
	_spring_active = false
	_following = false
	var target := clamp_focus(Vector3(pos.x, 0.0, pos.z))
	var t_target := zoom_t if dist_target <= 0.0 else zoom_t_for_distance(
			clampf(dist_target, d_min_m, _d_max_eff))
	t_target = clampf(t_target, 0.0, max_zoom_t())
	var d := Vector2(target.x - focus.x, target.z - focus.z).length()
	_jump_from = focus
	_jump_to = target
	_jump_t_from = zoom_t
	_jump_t_to = t_target
	_jump_elapsed = 0.0
	if reduce_motion:
		focus = target
		_raw_focus = target
		set_zoom_t(t_target)
		_jump_active = false
		return
	if d <= jump_arc_threshold_m:
		_jump_arc = false
		_jump_dur = jump_tween_s
		_jump_t_peak = t_target
	else:
		_jump_arc = true
		_jump_dur = jump_arc_tween_s
		_jump_t_peak = minf(1.0, maxf(zoom_t, t_target) + jump_arc_zoom_bump_t)
		_jump_t_peak = clampf(_jump_t_peak, 0.0, max_zoom_t())
	_jump_active = true


func is_jumping() -> bool:
	return _jump_active


## Drawer-aware framing: shift the focus along the screen-right axis so the
## target lands centred in the *visible* area rather than the whole viewport.
func drawer_focus_offset(drawer_w_dp: float, viewport_dp: Vector2) -> Vector3:
	return ground_right() * (drawer_w_dp * 0.5 * m_per_dp(viewport_dp))


func set_follow_target(pos: Vector3) -> void:
	_following = true
	_follow_pos = Vector3(pos.x, 0.0, pos.z)


func clear_follow() -> void:
	_following = false


func is_following() -> bool:
	return _following


# ---------------------------------------------------------------------------
# Time integration
# ---------------------------------------------------------------------------

## One frame of camera time: jump tween, follow, momentum, rubber-band spring and
## the yaw snap. Deterministic and dt-independent for the momentum term.
func advance(dt: float) -> void:
	if dt <= 0.0:
		return
	_advance_yaw_snap(dt)
	# The pitch axis is independent of the focus terms below — a fling can coast
	# while the tilt settles, and a jump does not cancel the angle the player
	# chose to look at the city from.
	if not _tilting:
		_advance_pitch(dt)
	if _jump_active:
		_advance_jump(dt)
		return
	if _following:
		focus = focus.lerp(_follow_pos, 1.0 - exp(-follow_lerp_k * dt))
		_raw_focus = focus
		return
	if _momentum_active:
		_advance_momentum(dt)
	elif _spring_active:
		_advance_spring(dt)


func _advance_momentum(dt: float) -> void:
	# Exact integration of dv/dt = -K·v: Δx = v·(1 − e^{−K·dt}) / K. The literal
	# Euler form in doc 12 §2.16 (`focus += v*dt; v *= exp(-K*dt)`) overshoots the
	# doc's own worked coast distance (60 m/s → 10 m) by ~5% at 60 Hz and is
	# frame-rate dependent; this closed form reproduces 60/6 = 10 m exactly and is
	# identical at any dt.
	var decay := exp(-momentum_decay_k * dt)
	_translate_focus(_momentum_v * ((1.0 - decay) / momentum_decay_k))
	_momentum_v *= decay
	if _momentum_v.length() < momentum_stop_m_s:
		_momentum_active = false
		_momentum_v = Vector3.ZERO
		if is_out_of_bounds():
			_start_spring()
		else:
			_rubber_active = false
			_raw_focus = focus
	elif is_out_of_bounds():
		# Coasting past the edge stops the fling and hands over to the spring.
		_momentum_active = false
		_momentum_v = Vector3.ZERO
		_start_spring()


func _start_spring() -> void:
	_rubber_active = false
	_raw_focus = focus
	_spring_v = Vector3.ZERO
	_spring_active = true


## Critically damped return, a = −ω²(x − x_clamped) − 2ωv, integrated in closed
## form: for the critically damped case x(t) = (A + B·t)·e^{−ωt} with A = x₀ and
## B = v₀ + ω·x₀. Exact, never overshoots, and — like the momentum term —
## identical at any frame rate, which is what makes the return deterministic.
func _advance_spring(dt: float) -> void:
	var target := clamp_focus(focus)
	var a := focus - target
	var b := _spring_v + a * spring_omega
	var decay := exp(-spring_omega * dt)
	var x := (a + b * dt) * decay
	_spring_v = (b - (a + b * dt) * spring_omega) * decay
	focus = target + x
	focus.y = 0.0
	_spring_v.y = 0.0
	_raw_focus = focus
	if focus.distance_to(target) < 0.001 and _spring_v.length() < 0.01:
		focus = target
		_raw_focus = target
		_spring_v = Vector3.ZERO
		_spring_active = false


func is_springing() -> bool:
	return _spring_active


func _advance_yaw_snap(dt: float) -> void:
	if not _yaw_snap_active:
		return
	_yaw_snap_elapsed += dt
	var x := 1.0 if rotation_snap_tween_s <= 0.0 \
			else clampf(_yaw_snap_elapsed / rotation_snap_tween_s, 0.0, 1.0)
	var deg := _yaw_snap_from + (_yaw_snap_to - _yaw_snap_from) * CameraState.ease_out_back(x)
	yaw = wrapf(deg_to_rad(deg), -PI, PI)
	if x >= 1.0:
		yaw = wrapf(deg_to_rad(_yaw_snap_to), -PI, PI)
		_yaw_snap_active = false


func _advance_jump(dt: float) -> void:
	_jump_elapsed += dt
	var x := 1.0 if _jump_dur <= 0.0 else clampf(_jump_elapsed / _jump_dur, 0.0, 1.0)
	if _jump_arc:
		var e := _ease_in_out_cubic(x)
		focus = _jump_from.lerp(_jump_to, e)
		# zoom_t rises to the bump at the midpoint, then settles on the target.
		zoom_t = clampf(
				lerpf(_jump_t_from, _jump_t_peak, _ease_in_out_cubic(minf(x * 2.0, 1.0)))
				if x < 0.5
				else lerpf(_jump_t_peak, _jump_t_to, _ease_in_out_cubic((x - 0.5) * 2.0)),
				0.0, max_zoom_t())
	else:
		var e := _ease_out_cubic(x)
		focus = _jump_from.lerp(_jump_to, e)
		zoom_t = clampf(lerpf(_jump_t_from, _jump_t_to, e), 0.0, max_zoom_t())
	focus.y = 0.0
	_raw_focus = focus
	if x >= 1.0:
		focus = _jump_to
		_raw_focus = focus
		set_zoom_t(_jump_t_to)
		_jump_active = false


static func _ease_out_cubic(x: float) -> float:
	var u := 1.0 - x
	return 1.0 - u * u * u


static func _ease_in_out_cubic(x: float) -> float:
	if x < 0.5:
		return 4.0 * x * x * x
	var u := -2.0 * x + 2.0
	return 1.0 - (u * u * u) * 0.5


# ---------------------------------------------------------------------------
# Persistence — the `ui.camera` block of doc 12 §3.2
# ---------------------------------------------------------------------------

## D-9's camera keys. `pitch_mode` is the word, `pitch_bias` the number, and both
## are written because a save that carried only the number could not tell AUTO
## apart from a bias that happened to land on the curve — and AUTO is a promise
## about what happens when the player zooms next, not a value.
func to_dict() -> Dictionary:
	return {
		"focus_x": focus.x,
		"focus_z": focus.z,
		"zoom_t": zoom_t,
		"yaw_deg": rad_to_deg(yaw),
		"pitch_mode": "auto" if pitch_auto else "manual",
		"pitch_bias": 0.0 if pitch_auto else pitch_bias,
	}


## Restore, through validation. A save may not resurrect an angle outside the
## authored band: `pitch_bias` is clamped to [-1, 1] and re-composed against the
## band *this build* authors, so retuning `pitch_manual_min_deg` retunes every
## restored city rather than leaving old saves pointing somewhere the data no
## longer allows. An unknown or missing `pitch_mode` reads as AUTO (§3.2's
## "missing keys take defaults").
func from_dict(d: Dictionary) -> void:
	set_zoom_t(UIConfig.get_num(d, "zoom_t", default_zoom_t))
	yaw = wrapf(deg_to_rad(UIConfig.get_num(d, "yaw_deg", default_yaw_deg)), -PI, PI)
	set_focus(Vector3(UIConfig.get_num(d, "focus_x", focus.x), 0.0,
			UIConfig.get_num(d, "focus_z", focus.z)))
	clear_pitch_bias()
	if str(d.get("pitch_mode", "auto")) != "manual":
		return
	var bias := UIConfig.get_num(d, "pitch_bias", 0.0)
	if not is_finite(bias):
		return
	set_pitch_bias(clampf(bias, -1.0, 1.0))
