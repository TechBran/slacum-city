class_name AndroidNative
extends RefCounted
## The optional bridge to the `SlacumNative` Kotlin plugin (doc 13 §2.6).
##
## Everything here degrades to a defined answer when the plugin is absent —
## desktop, the headless test runner, and any Android build exported without the
## Gradle template all take that path. `is_available()` is the only question a
## caller ever has to ask; every accessor is safe to call regardless.
##
## The plugin ships three capabilities and this class exposes exactly those:
##
## * **`elapsed_realtime_ms()`** — `SystemClock.elapsedRealtime()`, the clock that
##   keeps counting through deep sleep. `Time.get_ticks_msec()` (CLOCK_MONOTONIC)
##   stalls while the device sleeps, so it is only ever a *lower* bound on an
##   absence; this is the *upper* bound that catches a wall clock which jumped
##   forward. `AndroidLifecycle.measure_elapsed()` is the only consumer.
## * **`boot_id()`** — `elapsed_realtime_ms()` restarts at ~0 on reboot, so two
##   readings may only be subtracted when they share a boot id.
## * **thermal status + sustained performance** — doc 13 §2.8's inputs. This class
##   only reports and forwards; what a status *means* for the frame cap and the
##   graphics preset is doc 11's.
##
## * **`launch_args()`** — doc 13 D-20. The export template drops
##   `--esa command_line_params` on the floor, so the plugin reads the launching
##   Intent's extras itself and `DevArgs` merges the answer with
##   `OS.get_cmdline_user_args()`. Without it no dev argument reaches the game on
##   device and the runbook's whole scenario vocabulary is unreachable.
##
## A fourth capability **now ships**: the notification platform
## (`supports_notifications`, `ensure_channel`, `post_notification`,
## `schedule_notification`, `cancel_notifications`, the `POST_NOTIFICATIONS`
## permission flow, the launch payload). Doc 08 §2.13 owns the *policy* and lives
## in `game/notifications/`; doc 13 owns the *platform* and it is these methods
## plus `android/plugins/slacum_native/`. Every one of them still probes the
## singleton with `has_method` and degrades to "no", because the same GDScript
## runs on desktop, in the headless runner, and on a prebuilt-template APK where
## no plugin exists.
##
## Tests substitute the plugin by subclassing: override `is_available()` and the
## accessors, hand the instance to `AndroidLifecycle.native`, and no JNI is
## involved.

## Forwarded from `PowerManager.addThermalStatusListener` — `THERMAL_STATUS_*`,
## 0 NONE … 6 SHUTDOWN. Never emitted off-device.
signal thermal_status_changed(status: int)
## The answer to `request_notification_permission()`. Always arrives exactly once
## per request, including on API < 33 where no dialog can be shown.
signal permission_result(granted: bool)
## A scheduled notification fired while the process happened to be alive — a
## delivery receipt for doc 13 §3.2's `delivered_log`, never a control signal.
signal notification_delivered(id: int, key: String)
## The player tapped a notification and it brought the app up. Payload is the
## plan's deeplink (`incident/42`, `overlay/power`, …).
signal notification_opened(payload: String)

## The Android singleton the plugin registers itself as.
const SINGLETON_NAME := "SlacumNative"
## "No opinion" — distinct from `THERMAL_NONE`, which is a real measurement.
const THERMAL_UNKNOWN := -1
## `PowerManager.THERMAL_STATUS_NONE`, for callers that want to name the floor.
const THERMAL_NONE := 0

## `POST_NOTIFICATIONS` states, exactly as the plugin spells them (doc 13 §2.7).
const PERMISSION_GRANTED := "granted"
const PERMISSION_DENIED := "denied"
## Android has stopped showing the dialog; only system settings can change it now.
const PERMISSION_DENIED_PERMANENT := "denied_permanent"
const PERMISSION_NEVER_ASKED := "never_asked"
## No runtime permission exists here — API < 33, or no plugin at all.
const PERMISSION_UNSUPPORTED := "unsupported"

static var _shared: AndroidNative = null

var _plugin: Object = null


## The process-wide bridge — there is one plugin, so there is one of these. A
## bridge that found nothing is still a perfectly usable object; it just answers
## "unavailable" to everything. Shared rather than per-caller because attaching
## connects to a signal on an engine singleton that outlives every scene: a new
## instance per `AndroidLifecycle` would pile up connections across a scene
## reload and keep each dead bridge alive through them.
static func detect() -> AndroidNative:
	if _shared == null:
		_shared = AndroidNative.new()
		_shared.attach()
	return _shared


## Split out from `detect()` so a test can exercise the guard directly. Idempotent.
func attach() -> void:
	if _plugin != null:
		return
	if not Engine.has_singleton(SINGLETON_NAME):
		return
	_plugin = Engine.get_singleton(SINGLETON_NAME)
	if _plugin == null:
		return
	# Connected by name and only when the plugin declares them, so an older AAR
	# beside a newer GDScript degrades to "that signal never fires" instead of
	# throwing at bring-up.
	for pair: Array in [
			["thermal_status_changed", _on_thermal_status_changed],
			["permission_result", _on_permission_result],
			["notification_delivered", _on_notification_delivered],
			["notification_opened", _on_notification_opened]]:
		var signal_name: String = pair[0]
		var handler: Callable = pair[1]
		if _plugin.has_signal(signal_name):
			_plugin.connect(signal_name, handler)


func is_available() -> bool:
	return _plugin != null


# --------------------------------------------------------------------- time

## Milliseconds since boot including deep sleep, or -1 without the plugin.
func elapsed_realtime_ms() -> int:
	if _plugin == null:
		return -1
	return int(_plugin.elapsed_realtime_ms())


## The kernel's per-boot id, or "" when it is unknown — and "" must never be
## treated as "same boot", or a reboot would silently truncate an absence.
func boot_id() -> String:
	if _plugin == null:
		return ""
	return String(_plugin.boot_id())


# ------------------------------------------------------------ launch args

## The dev/QA arguments the launching Intent carried, verbatim (doc 13 D-20).
##
## `OS.get_cmdline_user_args()` answers `[]` on this export template no matter
## what `am start --esa command_line_params` was given, so the plugin reads the
## Intent extras itself and hands the list over here. **Nothing calls this
## directly** — `DevArgs.user_args()` merges it with the engine's own list and is
## the only list a consumer should read.
##
## Empty off-device, on a plugin-less build, and on every real player launch.
func launch_args() -> PackedStringArray:
	if _plugin == null or not _plugin.has_method("launch_args"):
		return PackedStringArray()
	var out := PackedStringArray()
	var raw: Variant = _plugin.launch_args()
	if raw is PackedStringArray:
		return raw
	if raw is Array:
		for value: Variant in (raw as Array):
			out.append(String(value))
	return out


# ------------------------------------------------------------------ thermal

## `PowerManager.THERMAL_STATUS_*`, or `THERMAL_UNKNOWN` when unavailable.
func thermal_status() -> int:
	if _plugin == null:
		return THERMAL_UNKNOWN
	return int(_plugin.thermal_status())


# ---------------------------------------------------- sustained performance

func is_sustained_performance_supported() -> bool:
	if _plugin == null:
		return false
	return bool(_plugin.is_sustained_performance_supported())


## Ask the SoC for a clock it can hold indefinitely instead of a boost it has to
## throttle out of. A no-op on devices that do not support it — this game is
## played in long sessions, so a level 60 fps beats a hot three minutes.
func set_sustained_performance(on: bool) -> void:
	if _plugin == null:
		return
	_plugin.set_sustained_performance(on)


# ----------------------------------------------------------- notifications

## True only on a build whose `SlacumNative` implements the notification
## surface. Still a probe rather than a constant, because the same GDScript runs
## on desktop, in the headless runner and on a prebuilt-template APK — and
## because an engine upgrade that shipped a stale AAR would otherwise crash on
## the first push instead of quietly falling back to "not delivered".
func supports_notifications() -> bool:
	return _plugin != null and _plugin.has_method("post_notification")


## One Android channel per enabled class, ids from `data/notifications.json`'s
## class table and `name` from the string table. Channels are part of the
## install, not part of a notification: a player who silences `slacum_routine` in
## Android's own settings has silenced P3 for good, which is the point (spec §49)
## — and it is also why the name can never be changed afterwards.
func ensure_channel(channel_id: String, name: String, importance: String,
		sound: bool, vibrate: bool) -> bool:
	if _plugin == null or channel_id == "" or not _plugin.has_method("ensure_channel"):
		return false
	return bool(_plugin.ensure_channel(channel_id, name, importance, sound, vibrate))


## Post or schedule one plan from `NotificationRouter`. A `fire_at_wall_ms` in
## the future is an alarm (inexact `setAndAllowWhileIdle`, doc 13 §2.6); absent or
## past means now. **No rate limiting on the far side** (report C-71) — the plan
## has already passed `NotificationBudget`.
func post_notification(plan: Dictionary) -> bool:
	if not supports_notifications():
		return false
	return bool(_plugin.post_notification(plan))


## The id-shaped call, for a caller that has a moment rather than a plan.
## `at_unix` is in **seconds**; a time already past posts immediately.
func schedule_notification(id: int, title: String, body: String, at_unix: int,
		priority: String = "routine") -> bool:
	if _plugin == null or not _plugin.has_method("schedule_notification"):
		return false
	return bool(_plugin.schedule_notification(id, title, body, at_unix, priority))


## Post right now. Only ever used by the shell's own diagnostics: an app in the
## foreground shows an in-app alert (doc 12), never a notification (doc 13 §2.5).
func show_notification(id: int, title: String, body: String,
		priority: String = "routine") -> bool:
	if _plugin == null or not _plugin.has_method("show_notification"):
		return false
	return bool(_plugin.show_notification(id, title, body, priority))


func cancel_notification(id: int) -> bool:
	if _plugin == null or not _plugin.has_method("cancel_notification"):
		return false
	return bool(_plugin.cancel_notification(id))


## Everything pending, dropped. doc 08 §2.13's resume step: the catch-up has
## replaced the future those alarms assumed, so they are re-planned rather than
## allowed to fire.
func cancel_notifications() -> int:
	if _plugin == null or not _plugin.has_method("cancel_notifications"):
		return 0
	return int(_plugin.cancel_notifications())


## The alarm ids the platform still holds, for a diagnostics screen and for the
## on-device tests in doc 13 §7 (D-02 … D-04).
func scheduled_ids() -> PackedInt32Array:
	if _plugin == null or not _plugin.has_method("scheduled_ids"):
		return PackedInt32Array()
	var raw: Variant = _plugin.scheduled_ids()
	var out := PackedInt32Array()
	if raw is PackedInt32Array:
		return raw
	if raw is Array:
		for value: Variant in (raw as Array):
			out.append(int(value))
	return out


# ------------------------------------------------------------- permissions

## Whether the system will actually show what we post. This is the only question
## worth asking before scheduling: it covers the runtime permission AND the
## per-app master switch, which exists on every API level and which no permission
## state reports.
func notifications_enabled() -> bool:
	if _plugin == null or not _plugin.has_method("notifications_enabled"):
		return false
	return bool(_plugin.notifications_enabled())


## One of the `PERMISSION_*` constants. Off-device this is `unsupported`, which
## is the honest answer: there is no permission to hold.
func permission_state() -> String:
	if _plugin == null or not _plugin.has_method("permission_state"):
		return PERMISSION_UNSUPPORTED
	return String(_plugin.permission_state())


## Show the system dialog; the answer arrives as `permission_result`. Returns
## false when there is no plugin to ask, and emits nothing in that case — the
## caller's state machine treats "no platform" and "denied" differently.
func request_notification_permission() -> bool:
	if _plugin == null or not _plugin.has_method("request_notification_permission"):
		return false
	_plugin.request_notification_permission()
	return true


## The only route left once Android has stopped showing the dialog.
func open_app_notification_settings() -> bool:
	if _plugin == null or not _plugin.has_method("open_app_notification_settings"):
		return false
	return bool(_plugin.open_app_notification_settings())


## The deeplink the app was opened from, or "". Consuming clears it, so a stale
## payload cannot deep-link the player into a three-day-old incident every launch.
func consume_launch_payload() -> String:
	if _plugin == null or not _plugin.has_method("consume_launch_payload"):
		return ""
	return String(_plugin.consume_launch_payload())


func _on_thermal_status_changed(status: int) -> void:
	thermal_status_changed.emit(status)


func _on_permission_result(granted: bool) -> void:
	permission_result.emit(granted)


func _on_notification_delivered(id: int, key: String) -> void:
	notification_delivered.emit(id, key)


func _on_notification_opened(payload: String) -> void:
	notification_opened.emit(payload)
