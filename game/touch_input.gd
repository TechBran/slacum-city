class_name TouchInput
extends Node
## Touch routing: Godot ScreenTouch/ScreenDrag → GestureRecognizer →
## CameraState. Pan begins on the recognizer's first pan of a stroke and the
## anchor is shared with pinch/twist (full one-hand RST manipulation).
## Mouse emulation is disabled project-wide so desktop mouse and device touch
## never double-apply.

signal tapped(position: Vector2)
signal long_pressed(position: Vector2)

var camera_state: CameraState
var recognizer: GestureRecognizer
var _pan_active := false
var _time_ms := 0.0


func setup(p_camera_state: CameraState, ui_config: UIConfig = null) -> void:
	camera_state = p_camera_state
	recognizer = GestureRecognizer.new(
			ui_config.gestures() if ui_config != null else {})


func _process(delta: float) -> void:
	_time_ms += delta * 1000.0
	if recognizer != null:
		_apply(recognizer.tick(_time_ms))


func _input(event: InputEvent) -> void:
	# Earliest-stage debug trace: what does Android actually deliver?
	if OS.is_debug_build() and not (event is InputEventMouseMotion):
		print("[input-stage] ", event.get_class())


func _unhandled_input(event: InputEvent) -> void:
	if recognizer == null:
		return
	if OS.is_debug_build() and (event is InputEventScreenTouch or event is InputEventScreenDrag):
		print("[touch] ", event.get_class(), " ", event)
	var viewport := Vector2(get_viewport().get_visible_rect().size)
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		_apply(recognizer.feed({"type": "down" if touch.pressed else "up",
				"index": touch.index, "position": touch.position, "time": _time_ms}))
		if not touch.pressed and _pan_active and recognizer.finger_count() == 0:
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
		if OS.is_debug_build():
			print("[gesture] ", g.get("kind", "?"))
		match StringName(String(g.get("kind", g.get("type", "")))):
			&"pan":
				var pos: Vector2 = g["position"]
				if not _pan_active:
					_pan_active = true
					camera_state.begin_pan(pos, viewport)
				else:
					camera_state.update_pan(pos, viewport, get_process_delta_time())
			&"pinch_begin":
				camera_state.begin_pan(g["centroid"], viewport)
				_pan_active = true
			&"pinch":
				camera_state.apply_pinch(float(g["span_prev"]), float(g["span"]),
						g["centroid"], viewport)
			&"twist":
				camera_state.apply_twist(deg_to_rad(float(g["delta_deg"])),
						g["centroid"], viewport)
			&"tap":
				tapped.emit(g.get("position", Vector2.ZERO))
			&"double_tap":
				camera_state.step_zoom(g.get("position", Vector2.ZERO), viewport, 1)
			&"two_finger_tap":
				camera_state.step_zoom(g.get("position", Vector2.ZERO), viewport, -1)
			&"long_press":
				long_pressed.emit(g.get("position", Vector2.ZERO))
