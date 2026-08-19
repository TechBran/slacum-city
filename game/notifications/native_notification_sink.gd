class_name NativeNotificationSink
extends NotificationSink
## The `SlacumNative` half of the notification seam (doc 13 §2.6, phase 2).
##
## This class is **already correct and already wired, and does nothing** — which
## is exactly the state doc 13 phase 2 needs to find. `AndroidNative` reports
## whether the plugin implements the notification surface at all
## (`supports_notifications()`, a `has_method` probe on the singleton), and today
## it does not: the Kotlin plugin ships `elapsedRealtime`, `boot_id`, thermal
## status and sustained performance, and nothing else. So `is_available()` is
## false on every build, `deliver()` returns false, and the router records the
## plan as undelivered.
##
## **Why probe instead of just not writing this.** Because the alternative is
## that the day the Kotlin side gains `postNotification`, somebody has to find
## every place a push decision is made and thread a new object through it. With
## the probe, that day is a Kotlin change plus a channel-id review, and the
## GDScript above this line is already right. The seam is not speculative
## generality: it is the difference between phase 2 being an afternoon and phase
## 2 being a refactor.
##
## What doc 13 phase 2 has to add on the Kotlin side, and nothing else:
##
##   * `ensure_channel(id, importance, sound, vibrate)` — one per enabled class,
##     ids from `NotificationConfig.classes()[*].channel_id`.
##   * `post_notification(payload)` — `{channel_id, title_key, body_key, args,
##     deeplink, key, fire_at_wall_ms}`. A `fire_at_wall_ms` in the future is an
##     alarm (inexact `setWindow`, ±`inexact_alarm_window_minutes`, per doc 08
##     §2.13.4); one in the past or absent is posted now.
##   * `cancel_notifications()` — everything pending, for the resume re-plan.
##
## Rate limiting is **not** on that list and must never be (report C-71): the
## plan handed to `deliver()` has already passed `NotificationBudget`.

var _native: AndroidNative
var _channels := 0
## Plans this sink was handed, whether or not it could post them. Kept so the
## seam is observable from a test and from a support log without the platform.
var _log: Array[Dictionary] = []


func _init(native: AndroidNative = null) -> void:
	_native = native if native != null else AndroidNative.detect()


func native() -> AndroidNative:
	return _native


func is_available() -> bool:
	return _native != null and _native.supports_notifications()


func ensure_channels(class_rows: Array) -> int:
	_channels = 0
	if not is_available():
		return 0
	for raw: Variant in class_rows:
		if not (raw is Dictionary):
			continue
		var row: Dictionary = raw
		# A class the slice ships disabled gets NO channel: an empty channel in
		# Android settings is a promise the game does not keep (report C-71 puts
		# P4 in the schema and out of the system UI for exactly this reason).
		if not bool(row.get("mvp_enabled", true)):
			continue
		if _native.ensure_channel(str(row.get("channel_id", "")),
				str(row.get("android_importance", "default")),
				bool(row.get("sound", false)), bool(row.get("vibrate", false))):
			_channels += 1
	return _channels


func channel_count() -> int:
	return _channels


func deliver(plan: Dictionary) -> bool:
	_log.append(plan)
	if not is_available():
		return false
	return _native.post_notification(plan)


func cancel_all() -> int:
	if not is_available():
		return 0
	return _native.cancel_notifications()


## Everything this sink was asked to deliver, oldest first.
func log_entries() -> Array[Dictionary]:
	return _log.duplicate()


func clear_log() -> void:
	_log.clear()
