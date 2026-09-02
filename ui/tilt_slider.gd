class_name TiltSlider
extends Control
## The right-edge TILT slider (doc 12 §2.23, Wave 17): one 48 dp touch column,
## vertically centred in the band the top bar and the bottom-right corner leave
## free, whose thumb rests at the middle detent — AUTO, the pitch curve's own
## answer — and leans the camera toward the facades when dragged UP and toward
## top-down when dragged DOWN. Release holds. A double tap snaps home with an
## ease. After `tilt_slider_fade_after_s` of nobody touching it the column ghosts
## to `tilt_slider_ghost_alpha`; any touch brings it back to full.
##
## Dumb by construction: every angle lives in `CameraState`'s manual pitch axis
## (`begin_tilt` / `apply_tilt` / `end_tilt` / `reset_pitch`), which is headless
## and shared with the two-finger gesture, so the slider and the gesture cannot
## disagree about what a lean is. This file turns dp into bias units at ONE gain
## — a full column is a full lean — and draws where the axis says the thumb is.
##
## **Why it is delta-driven and not an absolute slider.** The axis carries a
## rubber band past either end and a fling on release, exactly like the pan; an
## absolute thumb would have to fight both. So a press ON the thumb grabs it and
## every subsequent dp of travel is a delta into the axis, while a press on the
## track away from the thumb jumps the axis to that point first and then grabs.
## The thumb is drawn at the axis's clamped bias, so the elastic overshoot the
## gesture can feel is invisible here — the thumb simply stops at the end.
##
## **The range compresses with the zoom** (doc 92 §47's coupling, authored as
## `pitch_reach_*` in `data/ui.json.camera`): the reachable half of the track
## above the middle is `half_travel × reach_up(zoom_t)` dp and the half below is
## `half_travel × reach_down(zoom_t)`. At reach 1.0 that is the whole column; at
## less the lit track visibly shortens while the column keeps its 48 dp of touch.
## Nothing is silently clamped — the track shows how far this zoom will go.
##
## **It never captures a world pan.** The column is `MOUSE_FILTER_STOP`, so a
## stroke that STARTS on it is the slider's and never reaches `TouchInput`, and
## Godot routes a stroke by the control under its first sample — one that starts
## on the city and crosses the column stays the camera's. The `tilt_rest` and
## `tilt_drag` preview states in `tools/ui_preview.gd` photograph both faces.
##
## A8 (`reduce_motion`): the ghost fade and the snap-home ease are both cuts.
## The GHOST STATE itself is kept — it is information (the control is resting),
## not motion — which is the argument doc 12 §2.23 item 3 makes.

signal tilt_changed(bias: float, auto: bool)
signal reset_requested

const THUMB_GLYPH := "⇅"
const PALETTE_TYPE := "Palette"
## Half a fingertip of slop before a press stops being a candidate double tap.
const TAP_SLOP_DP := 8.0

var config: UIConfig
var camera: CameraState

var _thumb: Button
var _touch_min := 48.0
var _column_h := 240.0
var _min_h := 96.0
var _track_w := 4.0
var _tick_w := 14.0
var _fade_after_s := 2.0
var _fade_s := 0.25
var _ghost_alpha := 0.35
var _double_tap_ms := 260.0
var _reduce_motion := false

## The vertical band `UIRoot` hands over — safe-area dp, top and bottom of the
## space between the top bar and the corner rail. `set_band()` lays out from it.
var _band_top := 0.0
var _band_bottom := 0.0
## Whether a right-edge surface (a panel, the drawer) has taken the edge. The
## slider stands down rather than draw a thumb under a sheet (D-16's rule).
var _yielding := false
## Stood down for lack of room (band shorter than `tilt_slider_min_h_dp`).
var _stood_down := false

var _pressed := false
var _press_index := -1
var _press_pos := Vector2.ZERO
var _press_ms := -1.0e9
var _last_y := 0.0
var _moved_dp := 0.0
var _last_tap_ms := -1.0e9
var _last_tap_pos := Vector2.ZERO
var _idle_s := 0.0
var _last_bias := 0.0
var _last_auto := true
## Preview seam: hold a bias and the pressed face with no finger down.
var _preview_bias := 0.0
var _preview_held := false


## `game/main.gd` calls `UIRoot.bind_camera()`, which calls this; tests and the
## preview harness hand over their own `CameraState`. Idempotent.
func setup(cfg: UIConfig = null, p_camera: CameraState = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	if p_camera != null:
		camera = p_camera
	var defaults := config.section("defaults")
	_reduce_motion = bool(defaults.get("reduce_motion", false))
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	var cam := config.camera()
	_column_h = UIConfig.get_num(cam, "tilt_slider_h_dp", 240.0)
	_min_h = UIConfig.get_num(cam, "tilt_slider_min_h_dp", 96.0)
	_track_w = UIConfig.get_num(cam, "tilt_slider_track_w_dp", 4.0)
	_tick_w = UIConfig.get_num(cam, "tilt_slider_tick_w_dp", 14.0)
	_fade_after_s = UIConfig.get_num(cam, "tilt_slider_fade_after_s", 2.0)
	_fade_s = UIConfig.get_num(cam, "tilt_slider_fade_s", 0.25)
	_ghost_alpha = clampf(UIConfig.get_num(cam, "tilt_slider_ghost_alpha", 0.35), 0.0, 1.0)
	_double_tap_ms = UIConfig.get_num(cam, "tilt_slider_double_tap_ms", 260.0)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_NONE
	tooltip_text = UIWidgets.t(config, "ui_tilt_slider")
	_build_thumb()
	_apply_visibility()
	_place_thumb()
	set_process(true)
	queue_redraw()


func _ready() -> void:
	if config == null:
		setup(UIRoot.config_from(self))


func bind_camera(p_camera: CameraState) -> void:
	camera = p_camera
	_last_bias = 0.0 if camera == null else camera.pitch_bias
	_last_auto = true if camera == null else camera.is_pitch_auto()
	_apply_visibility()
	_place_thumb()
	queue_redraw()


## The thumb is a real, named, A3-sized Button so the accessibility walk sees the
## target — but it takes NO input of its own (`MOUSE_FILTER_IGNORE`): the column
## owns every press so a grab a few dp off the glyph still grabs. Its pressed
## face is driven by hand while a finger is down.
func _build_thumb() -> void:
	if _thumb == null:
		_thumb = UIWidgets.button("Thumb", THUMB_GLYPH,
				UIWidgets.t(config, "ui_tilt_thumb"),
				Vector2(_touch_min, _touch_min), &"RailButton")
		_thumb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_thumb.toggle_mode = true
		add_child(_thumb)
	_thumb.custom_minimum_size = Vector2(_touch_min, _touch_min)
	_thumb.tooltip_text = UIWidgets.t(config, "ui_tilt_thumb")


# ---------------------------------------------------------------------------
# Layout
# ---------------------------------------------------------------------------

## The band, in safe-area dp: `top` is the first free row under the top bar and
## `bottom` the last one above the corner rail's reservation. The column takes
## `tilt_slider_h_dp` of it when there is room, centred; less when there is not;
## and stands down below `tilt_slider_min_h_dp`.
func set_band(top: float, bottom: float) -> void:
	_band_top = top
	_band_bottom = bottom
	var band := bottom - top
	_stood_down = band < _min_h
	var h := clampf(band, 0.0, _column_h)
	var y := top + (band - h) * 0.5
	set_anchors_preset(Control.PRESET_TOP_RIGHT)
	offset_right = 0.0
	offset_left = -_touch_min
	offset_top = y
	offset_bottom = y + h
	size = Vector2(_touch_min, h)
	_apply_visibility()
	_place_thumb()
	queue_redraw()


## A right-edge surface is up (or went away). The slider yields the edge.
func set_yielding(value: bool) -> void:
	if _yielding == value:
		return
	_yielding = value
	if _pressed:
		_release()
	_apply_visibility()


func is_yielding() -> bool:
	return _yielding


## Stood down for lack of room — `false` whenever the column is on screen.
func is_stood_down() -> bool:
	return _stood_down


func _apply_visibility() -> void:
	visible = camera != null and not _yielding and not _stood_down


func column_height() -> float:
	return size.y


## Thumb-centre travel either side of the middle, in dp, at reach 1.0.
func half_travel() -> float:
	return maxf(0.0, (size.y - _touch_min) * 0.5)


func _mid_y() -> float:
	return size.y * 0.5


func _reach_up() -> float:
	return 1.0 if camera == null else camera.reach_up_at(camera.zoom_t)


func _reach_down() -> float:
	return 1.0 if camera == null else camera.reach_down_at(camera.zoom_t)


## Where the thumb's centre sits for a bias: up the column for a positive lean,
## down it for a negative one, each side scaled by its reach.
func thumb_y_for_bias(bias: float) -> float:
	var b := clampf(bias, -1.0, 1.0)
	if b >= 0.0:
		return _mid_y() - b * half_travel() * _reach_up()
	return _mid_y() - b * half_travel() * _reach_down()


## The inverse: the bias a thumb centre at `y` means, at the current reach.
func bias_for_thumb_y(y: float) -> float:
	var half := half_travel()
	if half <= 0.0:
		return 0.0
	var d := _mid_y() - y
	if d >= 0.0:
		var reach := _reach_up()
		return 0.0 if reach <= 0.0 else clampf(d / (half * reach), 0.0, 1.0)
	var reach_d := _reach_down()
	return 0.0 if reach_d <= 0.0 else clampf(d / (half * reach_d), -1.0, 0.0)


func current_bias() -> float:
	if _preview_held:
		return _preview_bias
	return 0.0 if camera == null else camera.pitch_bias


func _place_thumb() -> void:
	if _thumb == null:
		return
	var y := thumb_y_for_bias(current_bias())
	_thumb.position = Vector2(0.0, y - _touch_min * 0.5)
	_thumb.size = Vector2(_touch_min, _touch_min)


## The thumb's rect in the column's own coordinates.
func thumb_rect() -> Rect2:
	return Rect2(_thumb.position, _thumb.size) if _thumb != null else Rect2()


func thumb_button() -> Button:
	return _thumb


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _gui_input(event: InputEvent) -> void:
	if camera == null:
		return
	# Godot synthesises a mouse event from every touch (`emulate_mouse_from_touch`);
	# the touch is the one this column reads, the echo is dropped.
	if event is InputEventMouse and event.device == InputEvent.DEVICE_ID_EMULATION:
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			if not _pressed:
				_press(touch.index, touch.position)
		elif _pressed and touch.index == _press_index:
			_release()
		accept_event()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if _pressed and drag.index == _press_index:
			_drag_to(drag.position)
		accept_event()
	elif event is InputEventMouseButton:
		var button := event as InputEventMouseButton
		if button.button_index != MOUSE_BUTTON_LEFT:
			return
		if button.pressed:
			if not _pressed:
				_press(-1, button.position)
		elif _pressed:
			_release()
		accept_event()
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _pressed and _press_index == -1 and (motion.button_mask & MOUSE_BUTTON_MASK_LEFT):
			_drag_to(motion.position)
			accept_event()


func _now_ms() -> float:
	return float(Time.get_ticks_msec())


## Finger down. On the thumb: grab. Elsewhere in the column: jump the axis to
## that point, then grab. Either way the grab is exact — `begin_tilt` kills any
## fling or return the axis was in the middle of.
func _press(index: int, pos: Vector2) -> void:
	_pressed = true
	_press_index = index
	_press_pos = pos
	_press_ms = _now_ms()
	_last_y = pos.y
	_moved_dp = 0.0
	_idle_s = 0.0
	_wake()
	if not thumb_rect().has_point(pos):
		camera.set_pitch_bias(bias_for_thumb_y(pos.y))
	camera.begin_tilt()
	if _thumb != null:
		_thumb.set_pressed_no_signal(true)
	_sync_from_axis()


## One sample of the drag: dp into bias units at the column's own gain (a full
## half-column is a full lean on that side), signed so UP is a positive lean.
func _drag_to(pos: Vector2) -> void:
	var dy := pos.y - _last_y
	_last_y = pos.y
	_moved_dp += absf(dy)
	_idle_s = 0.0
	if is_zero_approx(dy):
		return
	var half := half_travel()
	if half <= 0.0:
		return
	var reach := _reach_up() if camera.pitch_bias >= 0.0 else _reach_down()
	if reach <= 0.0:
		return
	camera.apply_tilt(-dy / (half * reach), Vector2.ZERO, Vector2.ZERO,
			get_process_delta_time())
	_sync_from_axis()


func _release() -> void:
	if not _pressed:
		return
	_pressed = false
	_press_index = -1
	if _thumb != null:
		_thumb.set_pressed_no_signal(false)
	camera.end_tilt()
	var now := _now_ms()
	var was_tap := _moved_dp <= TAP_SLOP_DP and (now - _press_ms) <= _double_tap_ms
	if was_tap and (now - _last_tap_ms) <= _double_tap_ms \
			and _press_pos.distance_to(_last_tap_pos) <= TAP_SLOP_DP * 3.0:
		_last_tap_ms = -1.0e9
		reset_home()
	elif was_tap:
		_last_tap_ms = now
		_last_tap_pos = _press_pos
	_idle_s = 0.0
	_sync_from_axis()


## The double-action: home to AUTO. Eased by the axis; a cut under A8.
func reset_home() -> void:
	if camera == null:
		return
	camera.reset_pitch(_reduce_motion)
	reset_requested.emit()
	_wake()
	_sync_from_axis()


## Test seam: the whole press → drag → release sequence, in column dp.
func simulate_drag(from_y: float, to_y: float, steps: int = 8) -> void:
	_press(0, Vector2(_touch_min * 0.5, from_y))
	for i in range(1, maxi(1, steps) + 1):
		_drag_to(Vector2(_touch_min * 0.5, lerpf(from_y, to_y, float(i) / float(steps))))
	_release()


## Test seam: two quick taps at the same point.
func simulate_double_tap(y: float = -1.0) -> void:
	var at := Vector2(_touch_min * 0.5, thumb_y_for_bias(current_bias()) if y < 0.0 else y)
	_press(0, at)
	_release()
	_press(0, at)
	_release()


func is_pressed() -> bool:
	return _pressed


# ---------------------------------------------------------------------------
# The resting state, and the frame
# ---------------------------------------------------------------------------

func _wake() -> void:
	_idle_s = 0.0
	modulate.a = 1.0


func is_ghosted() -> bool:
	return modulate.a <= _ghost_alpha + 0.001


func ghost_alpha() -> float:
	return _ghost_alpha


## Seconds of stillness before the column ghosts (`tilt_slider_fade_after_s`).
## Public because the preview harness winds the idle clock past it to photograph
## the resting face, and a harness reaching into a private field is a harness
## that breaks the next time the field moves.
func fade_after_s() -> float:
	return _fade_after_s


func _sync_from_axis() -> void:
	if camera == null:
		return
	var bias := camera.pitch_bias
	var auto := camera.is_pitch_auto()
	_place_thumb()
	queue_redraw()
	if not is_equal_approx(bias, _last_bias) or auto != _last_auto:
		_last_bias = bias
		_last_auto = auto
		tilt_changed.emit(bias, auto)


func _process(delta: float) -> void:
	if camera == null or not visible:
		return
	var moving := camera.is_tilting() or camera.is_pitch_coasting() \
			or camera.is_pitch_returning()
	if not is_equal_approx(camera.pitch_bias, _last_bias) \
			or camera.is_pitch_auto() != _last_auto:
		_sync_from_axis()
	elif moving:
		queue_redraw()
	if _pressed or moving or _preview_held:
		_idle_s = 0.0
		modulate.a = 1.0
		return
	_idle_s += delta
	var target := _ghost_alpha if _idle_s >= _fade_after_s else 1.0
	if _reduce_motion or _fade_s <= 0.0:
		modulate.a = target
	else:
		modulate.a = move_toward(modulate.a, target, delta / _fade_s)


## Advance the resting clock by hand — the headless tests have no frames.
func advance(delta: float) -> void:
	_process(delta)


## Preview seam (`tools/ui_preview.gd`'s `tilt_drag`): the thumb leaned to
## `bias` with the pressed face, full alpha, no finger. `preview_rest()` clears.
func preview_drag(bias: float) -> void:
	_preview_held = true
	_preview_bias = clampf(bias, -1.0, 1.0)
	if _thumb != null:
		_thumb.set_pressed_no_signal(true)
	_wake()
	_place_thumb()
	queue_redraw()


func preview_rest() -> void:
	_preview_held = false
	if _thumb != null:
		_thumb.set_pressed_no_signal(false)
	_place_thumb()
	queue_redraw()


## `reduce_motion` reaches every screen through `UIRoot._on_settings_changed`.
func apply_setting(key: StringName, value: Variant) -> void:
	if key == &"reduce_motion":
		_reduce_motion = bool(value)


func _palette(name: StringName, fallback: Color) -> Color:
	return get_theme_color(name, PALETTE_TYPE) if has_theme_color(name, PALETTE_TYPE) \
			else fallback


func _draw() -> void:
	if size.y <= 0.0:
		return
	var cx := size.x * 0.5
	var mid := _mid_y()
	var half := half_travel()
	var track := _palette(&"text_dim", Color(0.6, 0.64, 0.69))
	var lit := _palette(&"accent", Color(0.31, 0.66, 1.0))
	var tick := _palette(&"text", Color(0.9, 0.92, 0.94))
	# The reachable track: exactly as far as this zoom lets the thumb go. A
	# closed reach draws a short track, which is the whole point of drawing it.
	var top := mid - half * _reach_up()
	var bottom := mid + half * _reach_down()
	draw_rect(Rect2(cx - _track_w * 0.5, top, _track_w, bottom - top), track)
	# The lean itself, lit from the middle to the thumb.
	var y := thumb_y_for_bias(current_bias())
	if absf(y - mid) > 0.5:
		draw_rect(Rect2(cx - _track_w * 0.5, minf(y, mid), _track_w, absf(y - mid)), lit)
	# The middle tick: AUTO. Wider than the track so it reads as a detent.
	draw_rect(Rect2(cx - _tick_w * 0.5, mid - 1.0, _tick_w, 2.0), tick)
	# End caps at the reachable ends.
	draw_rect(Rect2(cx - _tick_w * 0.25, top - 1.0, _tick_w * 0.5, 2.0), track)
	draw_rect(Rect2(cx - _tick_w * 0.25, bottom - 1.0, _tick_w * 0.5, 2.0), track)
