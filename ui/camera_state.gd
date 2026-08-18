class_name CameraState
extends RefCounted
## The camera interaction model — doc 12 §2.16, headless and Node-free
## (constitution §3: all camera STATE math lives in `RefCounted` classes so it is
## testable without a scene tree).
##
## State is exactly `{focus (y=0), zoom_t ∈ [0,1], yaw}` (doc 12 §2.16). Distance,
## pitch, the camera transform, ground rays and screen projection are all
## derived. That triple is the whole handoff to doc 11 §2.5: the renderer's
## `CameraRig` reads `{focus, zoom_t, yaw}` (or the ready-made
## `camera_transform()`) each frame and never reads input.
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

# --- Interaction range (data/ui.json.camera) --------------------------------
var d_min_m := 18.0
var d_max_m := 420.0
var d_max_city_factor := 1.6
var d_max_city_min_m := 120.0
var pitch_near_deg := 34.0
var pitch_far_deg := 62.0
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

var _raw_focus := Vector3.ZERO  ## unbanded focus; `focus` is its rubber-banded view
var _rubber_active := false     ## true while dragging or coasting

var _panning := false
var _pan_anchor := Vector3.ZERO
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


func pitch_deg() -> float:
	return pitch_deg_at(zoom_t)


func pitch_rad() -> float:
	return deg_to_rad(pitch_deg())


func height_m() -> float:
	return distance() * sin(pitch_rad())


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

## Rig basis: yaw about +Y, then pitch down about X (Godot's YXZ Euler order).
func camera_basis() -> Basis:
	return Basis.from_euler(Vector3(-pitch_rad(), yaw, 0.0), EULER_ORDER_YXZ)


## Camera3D world position: focus + basis * (0, 0, D) = focus + (D·cos p·sin yaw,
## D·sin p, D·cos p·cos yaw). Height D·sin p reproduces doc 11 §2.5's table.
func camera_position() -> Vector3:
	return focus + camera_basis() * Vector3(0.0, 0.0, distance())


## Euler rotation for the Camera3D node (radians, YXZ).
func camera_rotation() -> Vector3:
	return Vector3(-pitch_rad(), yaw, 0.0)


func camera_transform() -> Transform3D:
	return Transform3D(camera_basis(), camera_position())


## Ground-plane right/forward unit vectors (screen-right and screen-up mapped
## onto y = 0). Used by drawer-aware `focus_on` offsets and by pan fallbacks.
func ground_right() -> Vector3:
	return Vector3(cos(yaw), 0.0, -sin(yaw))


func ground_forward() -> Vector3:
	return Vector3(-sin(yaw), 0.0, -cos(yaw))


## Metres of ground per dp at the focus depth, along the screen-right axis:
## the frame is 2·D·tan(h_half) metres wide across `viewport_dp.x` dp.
func m_per_dp(viewport_dp: Vector2) -> float:
	if viewport_dp.x <= 0.0:
		return 0.0
	return (2.0 * distance() * _tan_half_h(viewport_dp)) / viewport_dp.x


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


## Ray-cast a touch point to the ground plane y = 0. Guard (doc 12 §2.16): a ray
## near-parallel to the ground — or pointing above the horizon — has its
## intersection distance clamped to `dist * 4` instead of shooting to infinity.
func screen_to_ground(screen_dp: Vector2, viewport_dp: Vector2) -> Vector3:
	var ray := screen_ray(screen_dp, viewport_dp)
	var origin: Vector3 = ray["origin"]
	var dir: Vector3 = ray["direction"]
	var max_t := distance() * 4.0
	var t := max_t
	if dir.y < -ray_parallel_eps:
		t = minf(-origin.y / dir.y, max_t)
	var hit := origin + dir * t
	hit.y = 0.0
	return hit


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
	_pan_anchor = screen_to_ground(screen_dp, viewport_dp)


## Re-anchor without moving the camera (MULTI → PAN when one finger lifts:
## "re-anchor to the remaining finger, no jump").
func reanchor_pan(screen_dp: Vector2, viewport_dp: Vector2) -> void:
	_pan_anchor = screen_to_ground(screen_dp, viewport_dp)


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


func _lock_anchor(screen_dp: Vector2, viewport_dp: Vector2) -> void:
	_translate_focus(_pan_anchor - screen_to_ground(screen_dp, viewport_dp))


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
	var anchor := screen_to_ground(screen_dp, viewport_dp)
	set_zoom_t(new_t)
	_translate_focus(anchor - screen_to_ground(screen_dp, viewport_dp))


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

func to_dict() -> Dictionary:
	return {
		"focus_x": focus.x,
		"focus_z": focus.z,
		"zoom_t": zoom_t,
		"yaw_deg": rad_to_deg(yaw),
	}


func from_dict(d: Dictionary) -> void:
	set_zoom_t(UIConfig.get_num(d, "zoom_t", default_zoom_t))
	yaw = wrapf(deg_to_rad(UIConfig.get_num(d, "yaw_deg", default_yaw_deg)), -PI, PI)
	set_focus(Vector3(UIConfig.get_num(d, "focus_x", focus.x), 0.0,
			UIConfig.get_num(d, "focus_z", focus.z)))
