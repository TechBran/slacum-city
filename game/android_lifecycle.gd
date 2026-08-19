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
## When the `SlacumNative` plugin is present (a Gradle-built APK, doc 13 §2.6)
## the measurement gains an upper bound from `SystemClock.elapsedRealtime()` and
## the node forwards thermal status; without it — desktop, the headless runner,
## a prebuilt-template APK — every one of those paths is simply skipped and the
## behaviour is exactly what it was before the plugin existed.
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
## `PowerManager.THERMAL_STATUS_*` (0 NONE … 6 SHUTDOWN), forwarded from the
## `SlacumNative` plugin. Never fires without it, so nothing may depend on it —
## doc 13 §2.8's thermal ladder is an *extra* lever, not a required input.
signal thermal_status_changed(status: int)

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
## The `SlacumNative` bridge (doc 13 §2.6). Always non-null, but
## `native.is_available()` is false everywhere except a Gradle-built Android
## APK — desktop and the headless runner run the plugin-free path. Tests
## substitute a subclass.
var native: AndroidNative = AndroidNative.detect()

## Last measured absence, real seconds. 0 until the first resume.
var last_elapsed_wall_s: float = 0.0
## "" normally, else "clock_backwards" (device clock moved back while away, the
## monotonic floor won) or "clock_forward" (the wall clock claimed more time
## than `elapsedRealtime` allows, so the plugin's ceiling won).
var last_anomaly: String = ""
## True when the last measurement was checked against `elapsedRealtime` — false
## off-device, and false across a reboot, where the two readings are unrelated.
var last_cross_checked: bool = false
## Latest thermal reading, or `AndroidNative.THERMAL_UNKNOWN` if none has arrived.
var last_thermal_status: int = AndroidNative.THERMAL_UNKNOWN

var _paused_wall: float = -1.0
var _paused_mono: float = -1.0
## `SystemClock.elapsedRealtime()` at the pause, and the boot it was read in.
## -1 / "" mean "no plugin reading", which disables the upper-bound check.
var _paused_realtime_ms: int = -1
var _paused_boot_id: String = ""
var _last_back_save_mono: float = -1e9


func _init() -> void:
	# The pause sequence has to run even when the tree is paused by a modal.
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	bind_native()


## Connect to whatever the `native` bridge turned out to be. Separate from
## `_ready` so a test can swap `native` for a stub and call this by hand; safe
## to call twice.
func bind_native() -> void:
	if native == null or not native.is_available():
		return
	if not native.thermal_status_changed.is_connected(_on_thermal_status_changed):
		native.thermal_status_changed.connect(_on_thermal_status_changed)
	last_thermal_status = native.thermal_status()
	# Doc 13 §2.8: a city builder is played in half-hour sittings, so a clock the
	# SoC can hold beats a boost it has to throttle out of two minutes in.
	native.set_sustained_performance(true)


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
	_paused_realtime_ms = -1
	_paused_boot_id = ""
	if native != null and native.is_available():
		_paused_realtime_ms = native.elapsed_realtime_ms()
		_paused_boot_id = native.boot_id()
	paused.emit(_autosave())


func _on_resumed() -> void:
	var elapsed := 0.0
	if _paused_wall >= 0.0:
		elapsed = measure_elapsed(_wall(), _mono())
	else:
		last_cross_checked = false
	_paused_wall = -1.0
	_paused_mono = -1.0
	_paused_realtime_ms = -1
	_paused_boot_id = ""
	last_elapsed_wall_s = elapsed
	resumed.emit(elapsed)


func _on_back() -> void:
	back_requested.emit()
	var now := _mono()
	if now - _last_back_save_mono >= BACK_AUTOSAVE_MIN_INTERVAL_S:
		_last_back_save_mono = now
		_autosave()


## The elapsed-time rule (doc 13 §2.3), both halves.
##
## The wall clock is the only source that survives deep sleep and process death,
## and it is also the only one the user can move. It is therefore bracketed:
##
## * **Floor — `Time.get_ticks_msec()` (CLOCK_MONOTONIC).** It cannot run fast; it
##   only stalls while the device sleeps, so it is a hard LOWER bound. A wall
##   delta beneath it means the clock moved backwards, and the monotonic figure
##   wins.
## * **Ceiling — `SystemClock.elapsedRealtime()` via `SlacumNative`.** It keeps
##   counting through deep sleep, so it measures the absence exactly, and a wall
##   delta above it means the clock jumped forward (NTP, timezone, manual). Only
##   comparable within one boot: `elapsedRealtime` restarts at ~0 on reboot, so a
##   changed boot id disables the ceiling rather than truncating the absence.
##
## Without the plugin only the floor exists, which is exactly what shipped before
## it and is still what desktop runs. Capping the result at the 12 real hour
## offline cap is the sim's job, not ours (doc 01, ruling C-19).
func measure_elapsed(now_wall: float, now_mono: float) -> float:
	var raw := now_wall - _paused_wall
	var mono := maxf(0.0, now_mono - _paused_mono)
	last_anomaly = ""
	last_cross_checked = false
	if raw < mono - CLOCK_TOLERANCE_S:
		last_anomaly = "clock_backwards"
		return mono
	var elapsed := maxf(0.0, raw)
	var ceiling := _realtime_ceiling_s()
	if ceiling >= 0.0:
		last_cross_checked = true
		if elapsed > ceiling:
			last_anomaly = "clock_forward"
			elapsed = ceiling
	return elapsed


## The `elapsedRealtime` ceiling in seconds, or -1 when there is none: no plugin,
## no pause stamp, an unreadable boot id, a different boot, or a reading that
## went backwards (which can only mean the boot id lied). The tolerance is added
## once, for the same reason it exists on the floor — the two clocks are sampled
## a few milliseconds apart and neither is a stopwatch.
func _realtime_ceiling_s() -> float:
	if native == null or not native.is_available():
		return -1.0
	if _paused_realtime_ms < 0 or _paused_boot_id == "":
		return -1.0
	if native.boot_id() != _paused_boot_id:
		return -1.0
	var delta_ms := native.elapsed_realtime_ms() - _paused_realtime_ms
	if delta_ms < 0:
		return -1.0
	return float(delta_ms) / 1000.0 + CLOCK_TOLERANCE_S


func _on_thermal_status_changed(status: int) -> void:
	last_thermal_status = status
	thermal_status_changed.emit(status)


func _autosave() -> bool:
	if save_service == null or sim == null:
		return false
	save_service.autosave(sim)
	return save_service.last_error == ""


func _wall() -> float:
	return float(wall_clock.call())


func _mono() -> float:
	return float(mono_clock.call())
