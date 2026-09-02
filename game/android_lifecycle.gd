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
## **THE COLD LAUNCH (Wave 17, report 98 §48 / RR-132).** There are two ways an
## Android app comes back and only one of them is a `RESUMED` notification. The
## other — process death, a swipe-away, the task switcher's X, a low-memory kill
## — brings back a *new process*, and until this wave that process resumed the
## city frozen at the pause, because the only pause reading this node had was
## [_paused_wall], an in-memory member that is `-1` at every boot. Core Rule 2
## was therefore void on the commonest path in the game.
##
## The fix has exactly one new idea in it: **the pause stamp is written to disk
## with the city** ([capture_stamp] → `save.android.last_pause`, doc 13 §3.2),
## and after a successful restore the shell calls [arm_cold_resume], which seeds
## a SYNTHETIC pause from that stamp and hands the absence to the *same*
## `resumed` signal an in-process resume uses. One code path owns catch-up, and
## the cold launch is not a second one. [pump_resume] is what fires it, on a
## frame the shell says is free — never while a restore cursor is stepping.
##
## The same queue carries the OTHER absence the old code dropped: one measured
## while a catch-up was already running ([defer_absence], RR-134).
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
## False while the shell holds a world that must never be committed — today
## that is the title door, where the founding city idles underneath and a
## lifecycle save would overwrite the player's newest autosave with it.
var save_enabled: bool = true
## doc 08 §2.13's notification planner, optional. When set, the pause sequence
## runs its scheduling pass (`plan_for_background`) and the resume sequence
## cancels and re-plans — the two moments the doc names, and the only two places
## in the game where a notification's *timing* is decided. Left null everywhere
## it is not wired, which is desktop and the headless runner.
var notification_router: NotificationRouter
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
## How many notification plans the last pause decided, and how many alarms the
## last resume cancelled. Diagnostics for doc 13 §3.2, and what the on-device
## smoke test asserts against `dumpsys alarm`.
var last_planned: int = 0
var last_cancelled: int = 0

var _paused_wall: float = -1.0
var _paused_mono: float = -1.0
## `SystemClock.elapsedRealtime()` at the pause, and the boot it was read in.
## -1 / "" mean "no plugin reading", which disables the upper-bound check.
var _paused_realtime_ms: int = -1
var _paused_boot_id: String = ""
var _last_back_save_mono: float = -1e9

# ------------------------------------------------- the cold launch (RR-132)

## `func() -> Dictionary` — the shell's answer to "is a catch-up in flight, and
## what is left of it?". `{}` means none. `Callable()` — desktop, the headless
## runner, every test that does not set it — also means none, so nothing here
## depends on it existing. `game/main.gd` binds it to its own
## `_catchup_remainder()`, which wraps `CatchUpCursor.remaining_plan()`.
var catchup_probe: Callable = Callable()

## What [_clock_ticks] answers when the sim has no readable clock. The class doc
## above says this node never reads [sim]; doc 13 §3.2's `clock_ticks` field is
## the one exception, it is read-only, and it is read for the stamp alone.
const _CLOCK_TICKS_UNKNOWN := 0

## Absences measured while a catch-up was already running, oldest first. Drained
## one per [pump_resume] (RR-134's SEQUENTIAL ruling — doc 93 §AG).
var deferred_absences: Array[float] = []
## Set by [pump_resume] immediately before it emits `resumed`, and taken by the
## shell with [take_unfinished_catchup]: the unspent tail of a plan a process
## death interrupted, in `CatchUpPlanner.plan`'s segment shape.
var pending_unfinished_catchup: Dictionary = {}
## The absence [arm_cold_resume] found, or -1 when nothing is armed.
var _cold_pending: float = -1.0
var _cold_unfinished: Dictionary = {}
## Diagnostics for the cold path, mirroring [last_elapsed_wall_s] /
## [last_anomaly]: what the last [arm_cold_resume] measured and why.
var last_cold_elapsed_s: float = 0.0
var last_cold_anomaly: String = ""


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
	# Doc 13 §3.2's stamp rides EVERY save, not only the pause one: the launch
	# that has to measure the absence cannot know which generation it will find,
	# and a periodic autosave the process was killed two seconds later is just as
	# much a "last time this city was awake" as a pause is (RR-132).
	if save_service != null:
		save_service.android_provider = capture_stamp


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
	# RR-134: a pause that lands while the catch-up veil is up commits a city
	# that is PART WAY through an absence, and it says so in its reason so a cold
	# launch can finish the plan rather than resume from the middle of it.
	var mid_catchup := not unfinished_catchup().is_empty()
	var saved := _autosave("pause_mid_catchup" if mid_catchup else "pause")
	# After the save, never before: doc 08 §2.13's pass schedules from fire times
	# "already in the save wherever possible", and a plan made against a city
	# that was then not committed would be a plan for a future that never was.
	#
	# The sim goes with it, because the plan is a *prediction*: construction that
	# completes at a known tick, and the Director events that were pre-rolled into
	# the save before the player left (doc 13 §2.4 classes (a) and (b)). Without a
	# sim this degrades to flushing whatever was queued, which is what desktop and
	# the headless runner do.
	#
	# ...and NOT AT ALL mid-catch-up (RR-134). The plan is a prediction made from
	# construction that completes at a known tick and Director events pre-rolled
	# into the save; a city halfway through a catch-up has neither settled yet,
	# so the alarms it would schedule are for a future that is still being
	# simulated. The resume — cold or warm — re-plans from the finished city.
	if notification_router != null and not mid_catchup:
		last_planned = notification_router.plan_for_background(sim, _paused_wall).size()
	paused.emit(saved)


func _on_resumed() -> void:
	var elapsed := 0.0
	var now_wall := _wall()
	if _paused_wall >= 0.0:
		elapsed = measure_elapsed(now_wall, _mono())
	else:
		last_cross_checked = false
	_paused_wall = -1.0
	_paused_mono = -1.0
	_paused_realtime_ms = -1
	_paused_boot_id = ""
	last_elapsed_wall_s = elapsed
	# doc 08 §2.13: on resume every pending alarm is cancelled and re-planned —
	# the catch-up about to run has replaced the future they were scheduled
	# against. Done BEFORE `resumed` so nothing the catch-up emits is cancelled
	# by a step that was supposed to precede it. The wall clock goes with it so
	# the budget can tell an alarm that rang from one that was cancelled first.
	if notification_router != null:
		last_cancelled = notification_router.replan_after_resume(now_wall)
	resumed.emit(elapsed)


# ------------------------------------------------------ the cold launch

## Doc 13 §3.2's `save.android` body, built for whatever moment this save is.
##
## On a pause the stamp is the PAUSE (the members below were written a few lines
## earlier in [_on_paused], before the snapshot, exactly as doc 13 §3.2's step
## table requires). On any other save it is NOW, because "now" is the last
## moment this city was known to be awake and that is the only thing the cold
## launch is asking. `clean` is what tells the two apart.
func capture_stamp() -> Dictionary:
	var paused_stamp := _paused_wall >= 0.0
	var unix_s := int(_paused_wall) if paused_stamp else int(_wall())
	var realtime := _paused_realtime_ms if paused_stamp else _native_realtime_ms()
	var boot := _paused_boot_id if paused_stamp else _native_boot_id()
	return {
		"section_version": LifecycleStamp.SECTION_VERSION,
		"last_pause": LifecycleStamp.build(unix_s, realtime, boot, _clock_ticks(),
				_app_version(), paused_stamp, unfinished_catchup()),
	}


## What the shell says is left of a catch-up in flight, or `{}`. Never throws and
## never assumes the probe is set — everything off device leaves it unset.
func unfinished_catchup() -> Dictionary:
	if not catchup_probe.is_valid():
		return {}
	var probe: Variant = catchup_probe.call()
	return probe if probe is Dictionary else {}


## THE COLD-LAUNCH SEAM (RR-132). Call it after ANY successful restore — the
## title door's CONTINUE, `--resume`'s `load_latest`, crash recovery.
##
## Answers true when the city is owed something, in which case [pump_resume]
## will hand it to `resumed` on the next frame the shell says is free. Answers
## false — and arms nothing — for a founding city (no save, no stamp), for a
## legacy format-1 load (no manifest, so no measurable absence), for an absence
## under a second, and for a device clock that moved backwards.
func arm_cold_resume(service: SaveService) -> bool:
	_cold_pending = -1.0
	_cold_unfinished = {}
	last_cold_elapsed_s = 0.0
	last_cold_anomaly = ""
	if service == null:
		return false
	var stamp := LifecycleStamp.read(service.last_loaded_android)
	if stamp.is_empty():
		# Every generation written before Wave 17 has no `android` section, and
		# `manifest.active.real_unix` has been written since the ladder shipped.
		# It is a wall reading with no bracket, which is the same information
		# desktop has always had, so it is credited on the same terms.
		stamp = LifecycleStamp.from_manifest_unix(service.last_loaded_real_unix)
	if stamp.is_empty():
		# A founding city, or a legacy format-1 load with no manifest. Neither
		# is a fault and neither owes anything, but the reason is recorded so a
		# "why did nothing happen" question has an answer.
		last_cold_anomaly = LifecycleStamp.ANOMALY_NO_STAMP
		return false
	var measured := LifecycleStamp.elapsed_since(stamp, _wall(), _native_realtime_ms(),
			_native_boot_id(), service.last_loaded_max_seen_unix)
	last_cold_elapsed_s = float(measured["elapsed_s"])
	last_cold_anomaly = String(measured["anomaly"])
	last_cross_checked = bool(measured["cross_checked"])
	var unfinished: Dictionary = stamp.get("unfinished", {})
	if last_cold_anomaly == LifecycleStamp.ANOMALY_BACKWARDS:
		# Doc 08 §2.9: we clamp, we never punish — and we say so, because a
		# player who moved their clock and got nothing deserves a reason in the
		# log rather than a city that silently stood still.
		push_warning("[catchup] device clock is behind this city's newest save "
				+ "(max_seen_unix %d); the absence credits 0"
				% service.last_loaded_max_seen_unix)
	if last_cold_elapsed_s < 1.0 and unfinished.is_empty():
		return false
	_cold_pending = last_cold_elapsed_s
	_cold_unfinished = unfinished
	return true


## True while something is queued for [pump_resume]: a cold-launch absence, or
## one deferred out of a catch-up. Diagnostics — the shell just pumps.
func owes_resume() -> bool:
	return _cold_pending >= 0.0 or not deferred_absences.is_empty()


## An absence measured while a catch-up was already running (RR-134). Queued,
## never merged and never dropped: doc 93 §AG rules the two absences SEQUENTIAL.
func defer_absence(elapsed_wall_s: float) -> void:
	if elapsed_wall_s > 0.0:
		deferred_absences.append(elapsed_wall_s)


## Hand the shell the next absence it owes, through the ordinary `resumed`
## signal. Call it once per frame from a frame with no restore and no catch-up
## cursor in flight; answers whether it fired.
func pump_resume() -> bool:
	var elapsed := -1.0
	var unfinished: Dictionary = {}
	if _cold_pending >= 0.0:
		elapsed = _cold_pending
		unfinished = _cold_unfinished
		_cold_pending = -1.0
		_cold_unfinished = {}
	elif not deferred_absences.is_empty():
		elapsed = deferred_absences.pop_front()
	if elapsed < 0.0:
		return false
	pending_unfinished_catchup = unfinished
	last_elapsed_wall_s = elapsed
	resumed.emit(elapsed)
	return true


## The unspent plan tail that came with the absence [pump_resume] just emitted,
## cleared as it is read. `{}` on every warm resume.
func take_unfinished_catchup() -> Dictionary:
	var out := pending_unfinished_catchup
	pending_unfinished_catchup = {}
	return out


func _native_realtime_ms() -> int:
	return native.elapsed_realtime_ms() if native != null and native.is_available() else -1


func _native_boot_id() -> String:
	return native.boot_id() if native != null and native.is_available() else ""


func _clock_ticks() -> int:
	if sim == null or not ("clock" in sim):
		return _CLOCK_TICKS_UNKNOWN
	var clock: Variant = sim.get("clock")
	if not (clock is Object) or not ("tick_index" in (clock as Object)):
		return _CLOCK_TICKS_UNKNOWN
	return int((clock as Object).get("tick_index"))


func _app_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", ""))


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


func _autosave(reason: String = "pause") -> bool:
	if save_service == null or sim == null or not save_enabled:
		return false
	# Doc 13 §2.2 step 3: lifecycle saves are `pause`-class, and the reason
	# rides `manifest.active.reason` so the ladder can tell them apart.
	save_service.autosave(sim, reason)
	return save_service.last_error == ""


func _wall() -> float:
	return float(wall_clock.call())


func _mono() -> float:
	return float(mono_clock.call())
