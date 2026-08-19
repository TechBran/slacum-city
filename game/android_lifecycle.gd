class_name AndroidLifecycle
extends Node
## The Android lifecycle router (doc 13 §2.2), MVP subset.
##
## Android can background the process and then kill it with no further
## callback, so the rule is simple: the city is committed to disk BEFORE the
## process is ever at risk — at `NOTIFICATION_APPLICATION_PAUSED`, and at a
## back press, which on Android is the other way out of the app. Nothing
## important is attempted in `_exit_tree` or `WM_CLOSE_REQUEST` on Android;
## those are best-effort only (doc 13 §2.2, "process-death safety").
##
## On resume this node measures how long the app was away and emits
## `resumed(elapsed_wall_s)`. It does NOT decide what that means: the 12 real
## hour offline cap, the coarse catch-up and the WHILE YOU WERE AWAY report
## are `CitySim`'s (doc 01 `catchup.offline_cap_real_ms`, ruling C-19). This
## node only measures, because `sim/` may never read a clock (constitution §5).
##
## Wire-up is two lines in `main.gd` — see the class docs of `SaveService`.

## Real seconds the app spent backgrounded, measured at resume.
signal resumed(elapsed_wall_s: float)
## The pause sequence ran. `saved` is false if the autosave was refused.
signal paused(saved: bool)
## The Android back button was pressed. `UIRoot` does the UI half; this is for
## anyone who wants to know the app may be about to leave the foreground.
signal back_requested()
## `NOTIFICATION_OS_MEMORY_WARNING` — doc 11's caches should shrink.
signal memory_warning()
## Focus changes: soft pause (audio, fps cap), never a save trigger.
signal focus_changed(has_focus: bool)

## A wall-clock reading further behind the monotonic clock than this is a
## clock change, not elapsed time (doc 13 §2.3 uses the same tolerance).
const CLOCK_TOLERANCE_S := 120.0
## Back is pressed to close sheets and panels too, so the back-triggered
## autosave is rate-limited. `APPLICATION_PAUSED` is never rate-limited:
## correctness beats budget (doc 13 §2.2).
const BACK_AUTOSAVE_MIN_INTERVAL_S := 5.0

var save_service: SaveService
## The live sim. Only ever handed to `SaveService`; never read here.
var sim: Object
## Injectable clocks (tests drive them; production uses `Time`).
## `wall` returns unix seconds, `mono` returns monotonic seconds.
var wall_clock: Callable = func() -> float: return Time.get_unix_time_from_system()
var mono_clock: Callable = func() -> float: return Time.get_ticks_msec() / 1000.0

## Last measured absence, real seconds. 0 until the first resume.
var last_elapsed_wall_s: float = 0.0
## "" normally, else "clock_backwards" — set when the device clock moved back
## while the app was away and the monotonic floor had to be used instead.
var last_anomaly: String = ""

var _paused_wall: float = -1.0
var _paused_mono: float = -1.0
var _last_back_save_mono: float = -1e9


func _init() -> void:
	# The pause sequence has to run even when the tree is paused by a modal.
	process_mode = Node.PROCESS_MODE_ALWAYS


## Wire the node to the save layer and the live sim.
func setup(p_save_service: SaveService, p_sim: Object) -> void:
	save_service = p_save_service
	sim = p_sim


func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_PAUSED:
			_on_paused()
		NOTIFICATION_APPLICATION_RESUMED:
			_on_resumed()
		NOTIFICATION_WM_GO_BACK_REQUEST:
			_on_back()
		NOTIFICATION_APPLICATION_FOCUS_IN:
			focus_changed.emit(true)
		NOTIFICATION_APPLICATION_FOCUS_OUT:
			focus_changed.emit(false)
		NOTIFICATION_OS_MEMORY_WARNING:
			memory_warning.emit()


# ----------------------------------------------------------------- sequences

func _on_paused() -> void:
	# Stamp first, save second: a kill between the two costs the elapsed
	# measurement, not the city.
	_paused_wall = _wall()
	_paused_mono = _mono()
	paused.emit(_autosave())


func _on_resumed() -> void:
	var elapsed := 0.0
	if _paused_wall >= 0.0:
		elapsed = measure_elapsed(_wall(), _mono())
	_paused_wall = -1.0
	_paused_mono = -1.0
	last_elapsed_wall_s = elapsed
	resumed.emit(elapsed)


func _on_back() -> void:
	back_requested.emit()
	var now := _mono()
	if now - _last_back_save_mono >= BACK_AUTOSAVE_MIN_INTERVAL_S:
		_last_back_save_mono = now
		_autosave()


## The elapsed-time rule (doc 13 §2.3, plugin-free half).
##
## The monotonic clock is a hard LOWER bound on real elapsed time — it cannot
## run fast, it only stalls in deep sleep — so a wall delta below it means the
## device clock moved backwards, and the monotonic figure wins. There is no
## upper-bound cross-check yet: that needs `SystemClock.elapsedRealtime()`
## from the `SlacumNative` plugin, which advances through deep sleep.
## Capping the result is the sim's job, not ours.
func measure_elapsed(now_wall: float, now_mono: float) -> float:
	var raw := now_wall - _paused_wall
	var mono := maxf(0.0, now_mono - _paused_mono)
	last_anomaly = ""
	if raw < mono - CLOCK_TOLERANCE_S:
		last_anomaly = "clock_backwards"
		return mono
	return maxf(0.0, raw)


func _autosave() -> bool:
	if save_service == null or sim == null:
		return false
	save_service.autosave(sim)
	return save_service.last_error == ""


func _wall() -> float:
	return float(wall_clock.call())


func _mono() -> float:
	return float(mono_clock.call())
