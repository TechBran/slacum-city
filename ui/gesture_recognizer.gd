class_name GestureRecognizer
extends RefCounted
## The touch state machine of doc 12 §2.16, pure and headless (constitution §3).
## Godot `InputEvent`s never reach this class: `TouchRouter._unhandled_input()`
## normalises them into plain dictionaries, so the whole recogniser is driven by
## synthetic streams in tests.
##
## Event in (one dictionary per touch sample):
##     {"type": "down"|"move"|"up", "index": int, "position": Vector2 (dp),
##      "time": float (milliseconds)}
## Gestures out: an Array of dictionaries, each with a `kind` StringName —
## `tap`, `double_tap`, `long_press`, `two_finger_tap`, `pan_begin`, `pan`,
## `pan_end`, `multi_begin`, `pinch_begin`, `pinch`, `twist_begin`, `twist`,
## `tilt_begin`, `tilt`, `tilt_end` (Wave 17's two-finger tilt, see `_emit_multi`).
##
## The chart (doc 12 §2.16):
##     IDLE ─(down f0)→ PENDING ─┬ up ≤220ms & ≤8dp        → TAP / DOUBLE_TAP
##                               ├ held ≥450ms & ≤10dp     → LONG_PRESS
##                               ├ travel >8dp             → PAN
##                               └ down f1 (≤80ms suppresses the pending tap) → MULTI
##     PAN  ─(down f1)→ MULTI ; ─(all up)→ pan_end
##     MULTI: centroid pan always; + ZOOM past 24 dp span change; + ROTATE past 8°
##            or TILT: 24 dp of vertical centroid travel with the span and bearing
##            still inside half of those deadzones — takes the stroke (Wave 17)
##            ─(one finger up)→ PAN, re-anchored to the remaining finger, no jump
##
## Two deliberate readings of the chart, both required by doc 12 §7:
##  * LONG_PRESS is evaluated **before** the drag slop, which is the only way
##    test 2's "460 ms at 9 dp travel → LONG_PRESS" and test 1's "9 dp in 180 ms
##    → PAN" can both hold — 9 dp is over `DRAG_START_SLOP` 8 but under
##    `LONGPRESS_SLOP` 10, so the discriminator is elapsed time, not distance.
##  * A qualifying second tap emits **only** `double_tap`, never `tap` as well,
##    so test 3's "300 ms apart → two TAPs" reads as the negative case it is.
##    (A double tap zooms; it must not also select.)
##
## The chart's MOMENTUM state belongs to `CameraState`, not here: `pan_end`
## reports the release velocity and the camera decides whether to coast.

enum State { IDLE, PENDING, PAN, MULTI }

const KIND_TAP := &"tap"
const KIND_DOUBLE_TAP := &"double_tap"
const KIND_LONG_PRESS := &"long_press"
const KIND_TWO_FINGER_TAP := &"two_finger_tap"
const KIND_PAN_BEGIN := &"pan_begin"
const KIND_PAN := &"pan"
const KIND_PAN_END := &"pan_end"
const KIND_MULTI_BEGIN := &"multi_begin"
const KIND_PINCH_BEGIN := &"pinch_begin"
const KIND_PINCH := &"pinch"
const KIND_TWIST_BEGIN := &"twist_begin"
const KIND_TWIST := &"twist"
const KIND_TILT_BEGIN := &"tilt_begin"
const KIND_TILT := &"tilt"
## The tilt stroke is over — the fingers lifted, or one of them did and the
## survivor is a PAN again. Emitted so the camera's `end_tilt()` (momentum, the
## rubber band's spring, the detent) runs exactly once per stroke.
const KIND_TILT_END := &"tilt_end"

# --- Thresholds (data/ui.json.gestures_dp_ms) --------------------------------
var tap_slop_dp := 8.0
var tap_max_ms := 220.0
var longpress_ms := 450.0
var longpress_slop_dp := 10.0
var double_tap_ms := 260.0
var double_tap_slop_dp := 24.0
var drag_start_slop_dp := 8.0
var pinch_span_slop_dp := 24.0
var twist_deadzone_deg := 8.0
var multi_suppress_ms := 80.0
## The tilt arm (Wave 17). See `_emit_multi` for the discrimination table.
var tilt_engage_dp := 24.0
var tilt_span_tolerance_dp := 12.0
var tilt_bearing_tolerance_deg := 4.0
var tilt_dominance_ratio := 1.5

# --- Observable results ------------------------------------------------------
var state: State = State.IDLE
## Every distinct classification seen since `reset()` — doc 12 test 1's
## "never both" is an assertion over this array.
var recognized: Array[StringName] = []
var last_gesture: StringName = &""

# --- Internals ---------------------------------------------------------------
var _fingers: Dictionary = {}      # index -> {start_pos, start_time, pos, time}
var _order: Array[int] = []        # touch indices in arrival order

var _pending_index := -1
var _pending_consumed := false

var _last_move_pos := Vector2.ZERO
var _last_move_time := 0.0
var _release_velocity := Vector2.ZERO

var _last_tap_pos := Vector2.ZERO
var _last_tap_time := -1.0e9
var _has_last_tap := false

var _multi_start_time := 0.0
var _multi_simultaneous := false
var _multi_start_centroid := Vector2.ZERO
var _span_engage := 0.0
var _angle_engage_deg := 0.0
var _span_prev := 0.0
var _angle_prev_deg := 0.0
var _zoom_engaged := false
var _twist_engaged := false
var _twist_cumulative_deg := 0.0
var _tilt_engaged := false
var _tilt_prev_centroid := Vector2.ZERO
var _tilt_cumulative_dp := 0.0


func _init(gestures_cfg: Dictionary = {}) -> void:
	if not gestures_cfg.is_empty():
		tap_slop_dp = UIConfig.get_num(gestures_cfg, "tap_slop_dp", tap_slop_dp)
		tap_max_ms = UIConfig.get_num(gestures_cfg, "tap_max_ms", tap_max_ms)
		longpress_ms = UIConfig.get_num(gestures_cfg, "longpress_ms", longpress_ms)
		longpress_slop_dp = UIConfig.get_num(gestures_cfg, "longpress_slop_dp", longpress_slop_dp)
		double_tap_ms = UIConfig.get_num(gestures_cfg, "double_tap_ms", double_tap_ms)
		double_tap_slop_dp = UIConfig.get_num(gestures_cfg, "double_tap_slop_dp", double_tap_slop_dp)
		drag_start_slop_dp = UIConfig.get_num(gestures_cfg, "drag_start_slop_dp", drag_start_slop_dp)
		pinch_span_slop_dp = UIConfig.get_num(gestures_cfg, "pinch_span_slop_dp", pinch_span_slop_dp)
		twist_deadzone_deg = UIConfig.get_num(gestures_cfg, "twist_deadzone_deg", twist_deadzone_deg)
		multi_suppress_ms = UIConfig.get_num(gestures_cfg, "multi_suppress_ms", multi_suppress_ms)
		tilt_engage_dp = UIConfig.get_num(gestures_cfg, "tilt_engage_dp", tilt_engage_dp)
		tilt_span_tolerance_dp = UIConfig.get_num(gestures_cfg, "tilt_span_tolerance_dp",
				tilt_span_tolerance_dp)
		tilt_bearing_tolerance_deg = UIConfig.get_num(gestures_cfg,
				"tilt_bearing_tolerance_deg", tilt_bearing_tolerance_deg)
		tilt_dominance_ratio = UIConfig.get_num(gestures_cfg, "tilt_dominance_ratio",
				tilt_dominance_ratio)


static func load_from_file() -> GestureRecognizer:
	return GestureRecognizer.new(UIConfig.load_from_files().gestures())


## Clears the machine and the observation log. Double-tap history is cleared too.
func reset() -> void:
	_fingers.clear()
	_order.clear()
	state = State.IDLE
	recognized.clear()
	last_gesture = &""
	_pending_index = -1
	_pending_consumed = false
	_has_last_tap = false
	_zoom_engaged = false
	_twist_engaged = false
	_tilt_engaged = false
	_release_velocity = Vector2.ZERO


func finger_count() -> int:
	return _order.size()


func saw(kind: StringName) -> bool:
	return recognized.has(kind)


func release_velocity_dp_s() -> Vector2:
	return _release_velocity


func is_zoom_engaged() -> bool:
	return _zoom_engaged


func is_twist_engaged() -> bool:
	return _twist_engaged


func twist_total_deg() -> float:
	return _twist_cumulative_deg


func is_tilt_engaged() -> bool:
	return _tilt_engaged


## Vertical centroid travel since the tilt engaged, in dp, screen-down positive.
func tilt_total_dp() -> float:
	return _tilt_cumulative_dp


# ---------------------------------------------------------------------------
# Feed
# ---------------------------------------------------------------------------

func feed(event: Dictionary) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var kind := str(event.get("type", ""))
	var index := int(event.get("index", 0))
	var pos: Vector2 = event.get("position", Vector2.ZERO)
	var time := float(event.get("time", 0.0))
	match kind:
		"down": _on_down(index, pos, time, out)
		"move": _on_move(index, pos, time, out)
		"up": _on_up(index, pos, time, out)
		_: push_warning("GestureRecognizer: unknown event type '%s'" % kind)
	return out


func feed_stream(events: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for e: Dictionary in events:
		out.append_array(feed(e))
	return out


## Time-only advance: fires LONG_PRESS when the finger has simply been held, with
## no further touch sample to carry the clock.
func tick(now_ms: float) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	if state == State.PENDING and not _pending_consumed:
		var f: Dictionary = _fingers.get(_pending_index, {})
		if not f.is_empty():
			_try_long_press(f, f["pos"], now_ms, out)
	return out


# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------

func _on_down(index: int, pos: Vector2, time: float, out: Array[Dictionary]) -> void:
	_fingers[index] = {"start_pos": pos, "start_time": time, "pos": pos, "time": time}
	if not _order.has(index):
		_order.append(index)
	if _order.size() == 1:
		state = State.PENDING
		_pending_index = index
		_pending_consumed = false
		_last_move_pos = pos
		_last_move_time = time
		_release_velocity = Vector2.ZERO
		return
	if _order.size() == 2:
		_enter_multi(time, out)
	# Fingers 3+ are tracked but ignored; the manipulation stays on the first two.


func _enter_multi(time: float, out: Array[Dictionary]) -> void:
	var first: Dictionary = _fingers[_order[0]]
	_multi_simultaneous = (time - float(first["start_time"])) <= multi_suppress_ms
	# Either way, entering MULTI kills the pending single-finger tap.
	_pending_consumed = true
	_pending_index = -1
	state = State.MULTI
	_multi_start_time = time
	_span_engage = _span()
	_span_prev = _span_engage
	_angle_engage_deg = _angle_deg()
	_angle_prev_deg = _angle_engage_deg
	_zoom_engaged = false
	_twist_engaged = false
	_twist_cumulative_deg = 0.0
	_tilt_engaged = false
	_tilt_cumulative_dp = 0.0
	_multi_start_centroid = _centroid()
	_tilt_prev_centroid = _multi_start_centroid
	_emit(out, KIND_MULTI_BEGIN, {
		"centroid": _multi_start_centroid, "span": _span_engage,
		"angle_deg": _angle_engage_deg, "simultaneous": _multi_simultaneous, "time": time,
	})
	# Re-anchor the camera on the centroid so the transition never jumps.
	_emit(out, KIND_PAN_BEGIN,
			{"position": _multi_start_centroid, "reanchor": true, "time": time}, &"pan")


func _on_move(index: int, pos: Vector2, time: float, out: Array[Dictionary]) -> void:
	if not _fingers.has(index):
		return
	var f: Dictionary = _fingers[index]
	var prev: Vector2 = f["pos"]
	f["pos"] = pos
	f["time"] = time
	match state:
		State.PENDING:
			if index != _pending_index or _pending_consumed:
				return
			if _try_long_press(f, pos, time, out):
				return
			if pos.distance_to(f["start_pos"]) > drag_start_slop_dp:
				# The anchor is the finger-DOWN point (doc 12 §2.16), so the world
				# tracks the finger 1:1 including the slop it took to decide.
				state = State.PAN
				_emit(out, KIND_PAN_BEGIN,
						{"position": f["start_pos"], "reanchor": false, "time": time}, &"pan")
				_last_move_pos = f["start_pos"]
				_last_move_time = float(f["start_time"])
				_emit_pan(out, pos, prev, time)
		State.PAN:
			_emit_pan(out, pos, prev, time)
		State.MULTI:
			_emit_multi(out, time)


func _try_long_press(f: Dictionary, pos: Vector2, time: float, out: Array[Dictionary]) -> bool:
	if (time - float(f["start_time"])) < longpress_ms:
		return false
	if pos.distance_to(f["start_pos"]) > longpress_slop_dp:
		return false
	_pending_consumed = true
	_emit(out, KIND_LONG_PRESS, {"position": pos, "time": time})
	return true


func _emit_pan(out: Array[Dictionary], pos: Vector2, prev: Vector2, time: float) -> void:
	var dt_ms := time - _last_move_time
	if dt_ms > 0.0:
		_release_velocity = (pos - _last_move_pos) / (dt_ms * 0.001)
	_last_move_pos = pos
	_last_move_time = time
	_emit(out, KIND_PAN, {"position": pos, "delta": pos - prev, "time": time}, &"pan")


## Per-frame order inside MULTI is tilt → twist → zoom → centroid pan, matching
## the camera's tilt/twist → zoom → anchor-lock ordering, so the anchored ground
## point stays under the fingers however many sub-gestures are live.
##
## **The discrimination table (Wave 17).** Three two-finger readings share one
## MULTI, and the first two compose while the third excludes them:
##
## | reading | engages on | composes with |
## |---|---|---|
## | ZOOM (pinch) | `\|span − span_engage\| > 24 dp` | twist, centroid pan |
## | ROTATE (twist) | `\|Δbearing\| > 8°` | zoom, centroid pan |
## | TILT | `\|Δcentroid.y\| > 24 dp` **and** `\|Δspan\| ≤ 12 dp` **and** `\|Δbearing\| ≤ 4°` **and** `\|Δy\| ≥ 1.5·\|Δx\|` **and** neither zoom nor twist has engaged | nothing — it takes the stroke |
##
## Tilt is the odd one out because its raw signal — the centroid translating — is
## the *same* signal centroid-pan reads. Two readings of one motion cannot both
## be right, so the tilt takes the whole stroke once it engages and never
## engages after a pinch or a twist has. Its own thresholds are deliberately
## HALF the other two's deadzones: a gesture already drifting toward a pinch
## (span past 12 dp) or a twist (bearing past 4°) is disqualified before it can
## steal them, which is what makes "neither pinch nor twist regresses" a property
## of the table rather than a hope.
func _emit_multi(out: Array[Dictionary], time: float) -> void:
	var centroid := _centroid()
	var span := _span()
	var angle := _angle_deg()

	if _try_tilt(out, centroid, span, angle, time):
		return

	if not _twist_engaged and absf(_wrap_deg(angle - _angle_engage_deg)) > twist_deadzone_deg:
		_twist_engaged = true
		_angle_prev_deg = angle
		_emit(out, KIND_TWIST_BEGIN, {"centroid": centroid, "angle_deg": angle, "time": time},
				&"twist")
	if _twist_engaged:
		var delta := _wrap_deg(angle - _angle_prev_deg)
		_angle_prev_deg = angle
		_twist_cumulative_deg += delta
		_emit(out, KIND_TWIST, {
			"centroid": centroid, "angle_deg": angle, "delta_deg": delta,
			"cumulative_deg": _twist_cumulative_deg, "time": time,
		}, &"twist")

	if not _zoom_engaged and absf(span - _span_engage) > pinch_span_slop_dp:
		_zoom_engaged = true
		_span_prev = span  # re-base so the 24 dp deadzone is absorbed, not applied
		_emit(out, KIND_PINCH_BEGIN, {"centroid": centroid, "span": span, "time": time},
				&"pinch")
	if _zoom_engaged:
		var scale := 1.0 if _span_prev <= 0.0 else span / _span_prev
		var cumulative := 1.0 if _span_engage <= 0.0 else span / _span_engage
		var span_prev := _span_prev
		_span_prev = span
		_emit(out, KIND_PINCH, {
			"centroid": centroid, "span": span, "span_prev": span_prev,
			"scale": scale, "cumulative_scale": cumulative, "time": time,
		}, &"pinch")

	_emit(out, KIND_PAN, {"position": centroid, "delta": centroid - _multi_start_centroid,
			"time": time}, &"pan")


## The TILT arm of the table above. Returns true when the tilt owns this sample,
## in which case `_emit_multi` emits nothing else for it.
##
## Engage is decided against the ENGAGE-time geometry, not the previous sample:
## a stroke that has drifted 12 dp of span or 4° of bearing since the fingers
## went down is on its way to being a pinch or a twist and is refused for good
## — `_zoom_engaged` / `_twist_engaged` then take it on a later sample, exactly
## as they would have without this arm. The engage travel itself is absorbed
## (re-based at `_tilt_prev_centroid`) the way the pinch absorbs its 24 dp
## deadzone: the first sample of a tilt reports the delta since engage, never
## the 24 dp it took to decide.
func _try_tilt(out: Array[Dictionary], centroid: Vector2, span: float,
		angle: float, time: float) -> bool:
	if not _tilt_engaged:
		if _zoom_engaged or _twist_engaged:
			return false
		var travel := centroid - _multi_start_centroid
		if absf(travel.y) <= tilt_engage_dp:
			return false
		if absf(span - _span_engage) > tilt_span_tolerance_dp:
			return false
		if absf(_wrap_deg(angle - _angle_engage_deg)) > tilt_bearing_tolerance_deg:
			return false
		if absf(travel.y) < tilt_dominance_ratio * absf(travel.x):
			return false
		_tilt_engaged = true
		_tilt_prev_centroid = centroid
		_tilt_cumulative_dp = 0.0
		_emit(out, KIND_TILT_BEGIN, {"centroid": centroid, "time": time}, &"tilt")
		return true
	var delta := centroid - _tilt_prev_centroid
	_tilt_prev_centroid = centroid
	_tilt_cumulative_dp += delta.y
	_emit(out, KIND_TILT, {
		"centroid": centroid, "delta": delta, "delta_dp": delta.y,
		"cumulative_dp": _tilt_cumulative_dp, "time": time,
	}, &"tilt")
	return true


func _on_up(index: int, pos: Vector2, time: float, out: Array[Dictionary]) -> void:
	var f: Dictionary = _fingers.get(index, {})
	if not f.is_empty():
		f["pos"] = pos
		f["time"] = time
	var was_state := state
	match was_state:
		State.PENDING:
			_resolve_pending(f, pos, time, out)
			_forget(index)
		State.PAN:
			_forget(index)
			if _order.is_empty():
				_end_pan(out, time)
		State.MULTI:
			# Decided while both fingers are still known, and emitted on the FIRST
			# release: real two-finger taps never lift on the same timestamp, and
			# waiting for the second finger would land after the MULTI → PAN hop.
			if _is_two_finger_tap(time):
				_emit(out, KIND_TWO_FINGER_TAP, {"position": _multi_start_centroid, "time": time})
			# The tilt ends with the FIRST finger up, before the PAN hop below:
			# the survivor is a pan again, and a tilt that outlived its second
			# finger would keep leaning the pitch off a single-finger drag.
			if _tilt_engaged:
				_tilt_engaged = false
				_emit(out, KIND_TILT_END, {"cumulative_dp": _tilt_cumulative_dp,
						"time": time}, &"tilt")
			_forget(index)
			if _order.size() == 1:
				# Re-anchor on the surviving finger; the camera must not jump.
				var remaining: Dictionary = _fingers[_order[0]]
				state = State.PAN
				_zoom_engaged = false
				_twist_engaged = false
				_last_move_pos = remaining["pos"]
				_last_move_time = time
				_emit(out, KIND_PAN_BEGIN,
						{"position": remaining["pos"], "reanchor": true, "time": time}, &"pan")
			elif _order.is_empty():
				_end_pan(out, time)
		_:
			_forget(index)


func _resolve_pending(f: Dictionary, pos: Vector2, time: float, out: Array[Dictionary]) -> void:
	if _pending_consumed:
		state = State.IDLE if _order.size() <= 1 else state
		return
	var elapsed := time - float(f.get("start_time", time))
	var travel: float = pos.distance_to(f.get("start_pos", pos))
	state = State.IDLE
	if elapsed <= tap_max_ms and travel <= tap_slop_dp:
		if _has_last_tap and (time - _last_tap_time) <= double_tap_ms \
				and pos.distance_to(_last_tap_pos) <= double_tap_slop_dp:
			_has_last_tap = false
			_emit(out, KIND_DOUBLE_TAP, {"position": pos, "time": time})
		else:
			_has_last_tap = true
			_last_tap_pos = pos
			_last_tap_time = time
			_emit(out, KIND_TAP, {"position": pos, "time": time})
		return
	# Too slow or too far to be a tap: it was a (very small) pan all along.
	_emit(out, KIND_PAN_BEGIN, {"position": f.get("start_pos", pos), "reanchor": false,
			"time": time}, &"pan")
	_release_velocity = Vector2.ZERO
	_emit(out, KIND_PAN_END, {"velocity_dp_s": Vector2.ZERO, "time": time}, &"pan")


func _is_two_finger_tap(time: float) -> bool:
	if not _multi_simultaneous or _zoom_engaged or _twist_engaged or _tilt_engaged:
		return false
	if _order.size() != 2:
		return false
	if (time - _multi_start_time) > tap_max_ms:
		return false
	return _centroid().distance_to(_multi_start_centroid) <= tap_slop_dp


func _end_pan(out: Array[Dictionary], time: float) -> void:
	state = State.IDLE
	_zoom_engaged = false
	_twist_engaged = false
	_tilt_engaged = false
	_emit(out, KIND_PAN_END, {"velocity_dp_s": _release_velocity, "time": time}, &"pan")


func _forget(index: int) -> void:
	_fingers.erase(index)
	_order.erase(index)
	if _order.is_empty():
		if state != State.IDLE:
			state = State.IDLE
		_pending_index = -1
		_pending_consumed = false


# ---------------------------------------------------------------------------
# Two-finger geometry
# ---------------------------------------------------------------------------

func _p(i: int) -> Vector2:
	return _fingers[_order[i]]["pos"]


func _centroid() -> Vector2:
	if _order.size() >= 2:
		return (_p(0) + _p(1)) * 0.5
	if _order.size() == 1:
		return _p(0)
	return Vector2.ZERO


func _span() -> float:
	return 0.0 if _order.size() < 2 else _p(0).distance_to(_p(1))


func _angle_deg() -> float:
	if _order.size() < 2:
		return 0.0
	var d := _p(1) - _p(0)
	return rad_to_deg(atan2(d.y, d.x))


static func _wrap_deg(a: float) -> float:
	return wrapf(a, -180.0, 180.0)


func _emit(out: Array[Dictionary], kind: StringName, payload: Dictionary,
		classification: StringName = &"") -> void:
	payload["kind"] = kind
	out.append(payload)
	var label := classification if classification != &"" else kind
	last_gesture = label
	if not recognized.has(label):
		recognized.append(label)
