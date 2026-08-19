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
## A fourth capability is **declared and not implemented**: the notification
## surface (`supports_notifications`, `ensure_channel`, `post_notification`,
## `cancel_notifications`). Doc 08 §2.13 owns the *policy* and it ships now in
## `game/notifications/`; doc 13 owns the *platform* and it is phase 2. Every one
## of those four methods probes the singleton with `has_method` and degrades to
## "no", so this file already describes the whole contract the Kotlin side has to
## satisfy — see `game/notifications/native_notification_sink.gd`, which is the
## seam's other half and is equally finished and equally inert.
##
## Tests substitute the plugin by subclassing: override `is_available()` and the
## accessors, hand the instance to `AndroidLifecycle.native`, and no JNI is
## involved.

## Forwarded from `PowerManager.addThermalStatusListener` — `THERMAL_STATUS_*`,
## 0 NONE … 6 SHUTDOWN. Never emitted off-device.
signal thermal_status_changed(status: int)

## The Android singleton the plugin registers itself as.
const SINGLETON_NAME := "SlacumNative"
## "No opinion" — distinct from `THERMAL_NONE`, which is a real measurement.
const THERMAL_UNKNOWN := -1
## `PowerManager.THERMAL_STATUS_NONE`, for callers that want to name the floor.
const THERMAL_NONE := 0

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
	if _plugin != null and _plugin.has_signal("thermal_status_changed"):
		_plugin.connect("thermal_status_changed", _on_thermal_status_changed)


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


# ------------------------------------------------------ notifications (phase 2)

## True only on a build whose `SlacumNative` implements the notification
## surface. It does not today, on any build — this is the probe that lets doc 08's
## router be finished and correct while doc 13's platform half is still to come,
## rather than the two having to land in the same change.
func supports_notifications() -> bool:
	return _plugin != null and _plugin.has_method("post_notification")


## One Android channel per enabled class, ids from `data/notifications.json`'s
## class table. Channels are part of the install, not part of a notification: a
## player who silences `slacum_routine` in Android's own settings has silenced
## P3 for good, which is the point (spec §49).
func ensure_channel(channel_id: String, importance: String, sound: bool,
		vibrate: bool) -> bool:
	if _plugin == null or channel_id == "" or not _plugin.has_method("ensure_channel"):
		return false
	return bool(_plugin.ensure_channel(channel_id, importance, sound, vibrate))


## Post or schedule one plan from `NotificationRouter`. A `fire_at_wall_ms` in
## the future is an alarm (inexact `setWindow`, per doc 08 §2.13.4); absent or
## past means now. **No rate limiting on the far side** (report C-71) — the plan
## has already passed `NotificationBudget`.
func post_notification(plan: Dictionary) -> bool:
	if not supports_notifications():
		return false
	return bool(_plugin.post_notification(plan))


## Everything pending, dropped. doc 08 §2.13's resume step: the catch-up has
## replaced the future those alarms assumed, so they are re-planned rather than
## allowed to fire.
func cancel_notifications() -> int:
	if _plugin == null or not _plugin.has_method("cancel_notifications"):
		return 0
	return int(_plugin.cancel_notifications())


func _on_thermal_status_changed(status: int) -> void:
	thermal_status_changed.emit(status)
