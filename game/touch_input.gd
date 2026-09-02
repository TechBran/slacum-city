class_name TouchInput
extends Node
## Touch routing: Godot ScreenTouch/ScreenDrag → GestureRecognizer →
## CameraState. Pan begins on the recognizer's first pan of a stroke and the
## anchor is shared with pinch/twist (full one-hand RST manipulation).
## `emulate_mouse_from_touch` is ON so Godot's GUI (ScrollContainer panning
## etc.) works on device; Main's mouse dev-controls skip those synthesised
## events by `DEVICE_ID_EMULATION`, so touch is only ever applied here.

signal tapped(position: Vector2)
signal long_pressed(position: Vector2)

## Every phase of a single-finger world stroke, whether or not anything claims
## it. A test seam and a hook; the routing decision is the Callable below.
signal drag_routed(phase: StringName, position: Vector2)

const PHASE_BEGIN := &"begin"
const PHASE_UPDATE := &"update"
const PHASE_END := &"end"

var camera_state: CameraState
var recognizer: GestureRecognizer
## **The world-drag router** (doc 12 §2.7's drag-path placement). A single-finger
## stroke on the world normally pans the camera; while a run tool is up it has to
## DRAW instead, and the decision cannot live here — this node knows nothing
## about build sheets.
##
## The shell sets one Callable, `func(phase: StringName, position: Vector2) ->
## bool`, called with `PHASE_BEGIN` on the finger-DOWN point (the recognizer's
## own anchor, doc 12 §2.16, so the run starts under the finger and not 8 dp
## along), then `PHASE_UPDATE` per move, then `PHASE_END`. It returns whether it
## CLAIMED the stroke; when it does not — the usual case — this file behaves
## exactly as it did before the router existed: one branch and no allocation.
##
## Two fingers are never routed: pinch and twist are the camera's, always, so a
## player mid-run can still frame the shot they are drawing into.
var world_drag_router: Callable = Callable()
var _pan_active := false
var _routing := false
## Wave 17: a two-finger TILT stroke is live (`GestureRecognizer.KIND_TILT_BEGIN`
## … `KIND_TILT_END`). The recogniser owns the discrimination; this only turns
## dp into bias units and closes the stroke exactly once.
var _tilt_active := false
var _time_ms := 0.0


func setup(p_camera_state: CameraState, ui_config: UIConfig = null) -> void:
	camera_state = p_camera_state
	recognizer = GestureRecognizer.new(
			ui_config.gestures() if ui_config != null else {})


func _process(delta: float) -> void:
	_time_ms += delta * 1000.0
	if recognizer != null:
		_apply(recognizer.tick(_time_ms))


func _unhandled_input(event: InputEvent) -> void:
	if recognizer == null:
		return
	var viewport := Vector2(get_viewport().get_visible_rect().size)
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		_apply(recognizer.feed({"type": "down" if touch.pressed else "up",
				"index": touch.index, "position": touch.position, "time": _time_ms}))
		if not touch.pressed and recognizer.finger_count() == 0:
			if _routing:
				_route(PHASE_END, touch.position)
				_routing = false
			# Belt and braces: the recogniser emits `tilt_end` on the first finger
			# up, so this only fires if a stroke lost its samples on the way here.
			if _tilt_active:
				_tilt_active = false
				camera_state.end_tilt()
			if _pan_active:
				_pan_active = false
				camera_state.end_pan()
				camera_state.release_twist()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		_apply(recognizer.feed({"type": "move", "index": drag.index,
				"position": drag.position, "time": _time_ms}))


func _apply(gestures: Array) -> void:
	var viewport := Vector2(get_viewport().get_visible_rect().size)
	for g in gestures:
		match StringName(String(g.get("kind", g.get("type", "")))):
			&"pan_begin":
				# The recognizer's anchor is the finger-DOWN point (§2.16), which
				# is the tile the run has to start on. Offered to the router
				# first; the camera's own lazy begin below is unchanged when the
				# router declines, so a city with no run tool up behaves exactly
				# as it did before this branch existed.
				_routing = _route(PHASE_BEGIN, g.get("position", Vector2.ZERO))
			&"pan":
				var pos: Vector2 = g["position"]
				if _routing:
					_route(PHASE_UPDATE, pos)
					continue
				if not _pan_active:
					_pan_active = true
					camera_state.begin_pan(pos, viewport)
				else:
					camera_state.update_pan(pos, viewport, get_process_delta_time())
			&"pinch_begin":
				# Two fingers are always the camera's. A run mid-draw survives
				# the pinch: the router is told the stroke ended, the anchor
				# stays pinned, and the player frames the shot they are drawing
				# into before carrying on.
				if _routing:
					_route(PHASE_END, g.get("centroid", Vector2.ZERO))
					_routing = false
				camera_state.begin_pan(g["centroid"], viewport)
				_pan_active = true
			&"pinch":
				camera_state.apply_pinch(float(g["span_prev"]), float(g["span"]),
						g["centroid"], viewport)
			&"twist":
				camera_state.apply_twist(deg_to_rad(float(g["delta_deg"])),
						g["centroid"], viewport)
			&"tilt_begin":
				# Wave 17 (doc 12 §2.23). Two fingers are still the camera's — a
				# run mid-draw is closed exactly as `pinch_begin` closes it.
				if _routing:
					_route(PHASE_END, g.get("centroid", Vector2.ZERO))
					_routing = false
				_tilt_active = true
				camera_state.begin_tilt()
			&"tilt":
				# Screen-up is a NEGATIVE dp delta and a POSITIVE lean (toward the
				# grazing floor — look up the facades), at the same dp-per-unit gain
				# the slider column uses. `tilt_invert` is the one data row that
				# flips it, for the player who reads a drag as pushing the horizon.
				var lean := 1.0 if camera_state.tilt_invert else -1.0
				camera_state.apply_tilt(
						lean * float(g["delta_dp"]) / camera_state.tilt_dp_per_unit,
						g["centroid"], viewport, get_process_delta_time())
			&"tilt_end":
				if _tilt_active:
					_tilt_active = false
					camera_state.end_tilt()
			&"tap":
				tapped.emit(g.get("position", Vector2.ZERO))
			&"double_tap":
				camera_state.step_zoom(g.get("position", Vector2.ZERO), viewport, 1)
			&"two_finger_tap":
				camera_state.step_zoom(g.get("position", Vector2.ZERO), viewport, -1)
			&"long_press":
				long_pressed.emit(g.get("position", Vector2.ZERO))


## Offers one phase of a single-finger stroke to the shell's router. Returns
## whether the router claimed it; `false` for every phase when no router is set,
## which is the state every screen but a run tool is in.
func _route(phase: StringName, position: Vector2) -> bool:
	drag_routed.emit(phase, position)
	if not world_drag_router.is_valid():
		return false
	return bool(world_drag_router.call(phase, position))


## Test seam: is a stroke currently being drawn rather than panned?
func is_routing() -> bool:
	return _routing


## Test seam: is a two-finger tilt stroke live?
func is_tilting() -> bool:
	return _tilt_active
