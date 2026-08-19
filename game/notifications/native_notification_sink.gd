class_name NativeNotificationSink
extends NotificationSink
## The `SlacumNative` half of the notification seam (doc 13 §2.5/§2.6) — **live**.
##
## Everything above this class decided; this class delivers. `NotificationRouter`
## has already classified the event, coalesced it, spent a token from doc 08's
## budget and resolved quiet hours; what arrives at `deliver()` is final, and
## report C-71 forbids this side from applying a second budget of its own. So the
## only decisions left here are platform ones:
##
## * **Copy.** A plan carries `title_key` / `body_key`; `NotificationText` renders
##   them out of `data/strings.en.json`, which is the same table the in-app row
##   reads, so a push and its feed entry can never drift (G-8).
## * **Ids.** `cancel_all()` runs before every batch (doc 08 §2.13's resume step),
##   so an id only has to be unique *within* a batch: `id_base + index`, 1000 up.
##   That makes the platform's persisted schedule trivially replaceable and kills
##   the whole class of stale-alarm bugs.
## * **Now or later.** A plan with `fire_at_wall_ms` in the future becomes an
##   inexact `AlarmManager` alarm; anything else is posted immediately. The
##   *shell* never posts while the app is foregrounded — that is an in-app alert
##   and doc 12 owns it — so in practice everything that reaches here during a
##   pause sequence is an alarm.
##
## **What "unavailable" means, and why it is not a failure.** Off-device, on a
## prebuilt-template APK, or with `POST_NOTIFICATIONS` denied, `deliver()` returns
## false and the router records the plan as undelivered. Nothing is lost: doc 08's
## rule is that the event is already in the ring and already in the WHILE YOU WERE
## AWAY report, and only the buzz is withheld. That is what lets the entire
## pipeline be tested headlessly.

## Doc 13 §2.5's id allocation: unique within a batch is enough.
const ID_BASE := 1000
## `delivered_log` in doc 13 §3.2 is a ring of 32; this is its live half.
const LOG_CAPACITY := 64

var _native: AndroidNative
var _text: NotificationText
var _channels := 0
var _id_base := ID_BASE
var _next_id := ID_BASE
## Plans this sink was handed, whether or not it could post them. Kept so the
## seam is observable from a test and from a support log without the platform.
var _log: Array[Dictionary] = []


func _init(native: AndroidNative = null, text: NotificationText = null) -> void:
	_native = native if native != null else AndroidNative.detect()
	_text = text if text != null else NotificationText.load_from_files()


func native() -> AndroidNative:
	return _native


func text() -> NotificationText:
	return _text


func is_available() -> bool:
	return _native != null and _native.supports_notifications()


func configure(delivery: Dictionary) -> void:
	_id_base = AudioConfig.get_int(delivery, "id_base", ID_BASE)
	_next_id = _id_base


## True when the platform will actually show what we post — the permission AND
## the per-app master switch. Kept separate from `is_available()` because the two
## have different consequences: no platform is a build fact, a denied permission
## is a player decision that the Settings row has to state honestly.
func can_post() -> bool:
	return is_available() and _native.notifications_enabled()


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
		var class_id := str(row.get("class_id", ""))
		if _native.ensure_channel(str(row.get("channel_id", "")),
				_text.channel_name(class_id),
				str(row.get("android_importance", "default")),
				bool(row.get("sound", false)), bool(row.get("vibrate", false))):
			_channels += 1
	return _channels


func channel_count() -> int:
	return _channels


## Post or schedule one decided plan. Returns whether the platform took it.
##
## The rendered title/body and the assigned `alarm_id` are written back into the
## plan dictionary, because doc 08's `notifications.scheduled[].alarm_id` has to
## be truthful and the WHILE YOU WERE AWAY report reconciles against the copy the
## player actually saw.
func deliver(plan: Dictionary) -> bool:
	var rendered := _text.render_plan(plan)
	plan["title"] = rendered["title"]
	plan["body"] = rendered["body"]
	var alarm_id := _next_id
	_next_id += 1
	plan["alarm_id"] = alarm_id
	_remember(plan)
	if not can_post():
		return false
	var payload := {
		"id": alarm_id,
		"channel_id": str(plan.get("channel_id", "")),
		"title": rendered["title"],
		"body": rendered["body"],
		"deeplink": str(plan.get("deeplink", "")),
		"key": str(plan.get("key", "")),
		"fire_at_wall_ms": int(plan.get("fire_at_wall_ms", 0)),
	}
	var posted := _native.post_notification(payload)
	plan["delivered"] = posted
	if not _log.is_empty():
		_log[_log.size() - 1]["delivered"] = posted
	return posted


func cancel_all() -> int:
	# Ids restart with the batch, exactly as doc 13 §2.5 specifies: the platform
	# is holding nothing by the time the next plan is built.
	_next_id = _id_base
	if not is_available():
		return 0
	return _native.cancel_notifications()


## The next id this sink would hand out — the assertion `tests/` makes about
## allocation being stable across re-runs.
func next_id() -> int:
	return _next_id


## Everything this sink was asked to deliver, oldest first.
func log_entries() -> Array[Dictionary]:
	return _log.duplicate()


func clear_log() -> void:
	_log.clear()


func _remember(plan: Dictionary) -> void:
	_log.append({
		"alarm_id": int(plan.get("alarm_id", 0)),
		"notify_id": str(plan.get("notify_id", "")),
		"class": str(plan.get("class", "")),
		"key": str(plan.get("key", "")),
		"title": str(plan.get("title", "")),
		"body": str(plan.get("body", "")),
		"fire_at_wall_ms": int(plan.get("fire_at_wall_ms", 0)),
		"delivered": false,
	})
	while _log.size() > LOG_CAPACITY:
		_log.remove_at(0)
