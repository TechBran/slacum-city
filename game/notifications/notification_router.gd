class_name NotificationRouter
extends RefCounted
## Where a sim event becomes *a notification* (doc 08 §2.13). One classifier,
## two destinations, and a seam.
##
##     sim event ──▶ NotificationRouter ──┬──▶ ui/alerts_model.gd   (in-app, now)
##                                        └──▶ NotificationSink     (push, doc 13 phase 2)
##
## **Why a router at all, when `AlertsModel` already ingests the same events.**
## Because they are two different decisions with two different budgets and doc
## 08 is emphatic that they must never be confused (report C-72). An in-app
## banner costs a glance the player is already giving; a push costs their
## attention while they are somewhere else. Doc 12's in-app rates are ~3x these,
## and the surest way to keep them apart is for one object to own the push
## decision and for that object to be the only thing that talks to the platform.
##
## What ships now
## --------------
##
## The in-app pipeline is **live**: `AlertsModel` reads the same
## `data/notifications.json` this class does, so a class is a class in both.
## The push pipeline is **decided but not delivered**: every plan is classified,
## coalesced and run through `NotificationBudget`, and then handed to a
## `NotificationSink` that is a no-op until doc 13 phase 2 gives it a platform.
## That is not a stub — the decisions are the hard part and they are all here and
## all tested; what is missing is the Kotlin that posts them.
##
## Three behaviours worth naming
## -----------------------------
##
## **Immediate in-app, batched push.** `feed_batch()` returns the plans at once —
## nothing about the feed row is delayed. Push candidates queue, and `flush()`
## is what spends tokens, because coalescing (*"3 problems in your city"*) can
## only be decided over a window and doc 08 §2.13's real scheduling pass runs at
## `pause`/`quit` anyway, when the fire times are known.
##
## **A denial is recorded, never dropped.** Doc 08: on deny the event still
## enters the ring and still appears in the report. Every plan this class makes
## is kept with its reason, and `notification_suppressed` carries the pair out.
##
## **One device-local clock read, here.** Quiet hours is the only wall-clock
## read in the game and it lives in the platform layer, never in `sim/`
## (constitution §5). `wall_clock` and `local_minute_of_day` are injectable
## Callables for exactly that reason: a test drives them and never touches `Time`.

## Emitted for every push decision that was refused. `reason` is one of
## `NotificationBudget`'s `REASON_*` constants.
signal notification_suppressed(key: String, reason: String)
## Emitted for every push plan that reached the sink, delivered or not.
signal notification_planned(plan: Dictionary)

const NOT_ROUTED := {}

var _cfg: NotificationConfig
var _budget: NotificationBudget
var _sink: NotificationSink
var _rules: Array = []

## Real minutes since the unix epoch. Monotone across a session and across a
## restart, which is what token buckets need; the default reads the system
## clock, and a test replaces it.
var wall_clock: Callable = func() -> float: return Time.get_unix_time_from_system() / 60.0
## Device-local minutes past midnight, 0..1439 — quiet hours' only input.
var local_minute_of_day: Callable = func() -> int:
	var now := Time.get_datetime_dict_from_system()
	return int(now["hour"]) * 60 + int(now["minute"])

## Push candidates waiting for a `flush()`.
var _pending: Array[Dictionary] = []
## Everything decided, newest last: allowed and refused alike.
var _plans: Array[Dictionary] = []
## Quiet-hours deferrals, waiting for the window to close (`defer_to_end`).
var _deferred: Array[Dictionary] = []
var _was_quiet := false
var _quiet_seen := false
var _seq := 0


func _init(cfg: NotificationConfig = null, sink: NotificationSink = null) -> void:
	_cfg = cfg if cfg != null else NotificationConfig.new()
	_budget = NotificationBudget.new(_cfg)
	_sink = sink if sink != null else NotificationSink.new()
	_rules = _cfg.alert_rules()


static func load_from_files(sink: NotificationSink = null) -> NotificationRouter:
	return NotificationRouter.new(NotificationConfig.load_from_files(), sink)


func config() -> NotificationConfig:
	return _cfg


func budget() -> NotificationBudget:
	return _budget


func sink() -> NotificationSink:
	return _sink


## Swap the platform in. Channels are created immediately, because a channel a
## player can see in system settings is part of the install and not part of a
## notification (spec §49).
func set_sink(new_sink: NotificationSink) -> void:
	_sink = new_sink if new_sink != null else NotificationSink.new()
	var rows: Array = []
	for class_id: String in _cfg.class_ids():
		var row := _cfg.class_def(class_id).duplicate(true)
		row["class_id"] = class_id
		rows.append(row)
	_sink.ensure_channels(rows)


# ---------------------------------------------------------------------------
# Ingest
# ---------------------------------------------------------------------------

## One sim event in, one push *candidate* out (or `{}` when the event is not
## notifiable). The candidate is queued, not sent: see `flush()`.
func feed(event: Dictionary) -> Dictionary:
	var rule := rule_for(event)
	if rule.is_empty():
		return NOT_ROUTED
	var notify_id := str(rule.get("notify_id", ""))
	if notify_id == "":
		return NOT_ROUTED
	var class_id := str(rule.get("push_class", "P3_routine"))
	var event_row := _cfg.event_def(notify_id)
	var key_name := str(rule.get("key", ""))
	var ref: Variant = event.get(key_name, null) if key_name != "" else null
	_seq += 1
	var candidate := {
		"seq": _seq,
		"notify_id": notify_id,
		"class": class_id,
		"in_app_class": _cfg.in_app_class(class_id),
		"severity": AudioConfig.get_int(event_row, "severity", 0),
		"aggregate": bool(event_row.get("aggregate", false)),
		"cooldown_minutes": AudioConfig.get_num(event_row, "cooldown_minutes", 0.0),
		"channel_id": str(_cfg.class_def(class_id).get("channel_id", "")),
		# doc 08 §3.3's convention, not authored copy: the sink resolves these.
		"title_key": "n_%s_title" % notify_id,
		"body_key": "n_%s_body" % notify_id,
		"deeplink": _deeplink(str(event_row.get("deeplink", "")), ref),
		# The per-key cooldown identity. `aggregate` events share one key (every
		# dark block is one outage), the rest are per entity.
		"key": notify_id if bool(event_row.get("aggregate", false)) or ref == null
				else "%s/%s" % [notify_id, str(ref)],
		"ref": ref,
		"event_type": str(event.get("type", "")),
		"at_min": _now_min(),
		"count": 1,
	}
	_pending.append(candidate)
	return candidate


## Drain-shaped ingest — the same batch `AlertsModel` and `AudioService` get.
func feed_batch(events: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw: Variant in events:
		if not (raw is Dictionary):
			continue
		var candidate := feed(raw)
		if not candidate.is_empty():
			out.append(candidate)
	return out


## First matching binding wins, so `data/notifications.json` orders the two
## `BlockDarkChanged` rules and the P1 incident rule ahead of the general one.
func rule_for(event: Dictionary) -> Dictionary:
	var type_name := str(event.get("type", ""))
	if type_name == "":
		return {}
	for raw: Variant in _rules:
		var rule: Dictionary = raw
		if str(rule.get("type", "")) != type_name:
			continue
		if not NotificationConfig.matches(rule.get("match", {}), event):
			continue
		return rule
	return {}


## `"incident/{ref}"` with the entity substituted, or the bare target when the
## event names nothing (`"overlay/power"`). A deeplink still carrying a hole is
## dropped: a tap that lands nowhere is worse than a notification you can only
## read.
static func _deeplink(template: String, ref: Variant) -> String:
	if template == "":
		return ""
	if not template.contains("{ref}"):
		return template
	if ref == null:
		return ""
	return template.replace("{ref}", str(ref))


# ---------------------------------------------------------------------------
# The push decision
# ---------------------------------------------------------------------------

## Decide every queued candidate: coalesce, budget, deliver or record.
##
## Returns the plans decided by this call. Called by the shell on
## `pause`/`quit` (doc 08 §2.13's scheduling pass) and whenever it wants the
## queue drained; calling it every frame is harmless and buys nothing.
func flush() -> Array[Dictionary]:
	var now_min := _now_min()
	var minute_of_day := _minute_of_day()
	var out: Array[Dictionary] = []
	out.append_array(_release_quiet_hours(now_min, minute_of_day))
	if _pending.is_empty():
		return out
	var queue := _coalesce(_pending, now_min)
	_pending.clear()
	for plan: Dictionary in queue:
		out.append(_decide(plan, now_min, minute_of_day))
	return out


## doc 08 §2.13.2's coalescing. *"If ≥ 3 notifications of one class would fire
## within `coalesce_window_minutes = 15`, they collapse into one summary
## carrying the highest severity — one token, not three."*
##
## Grouped by CLASS, not by event: three different problems are still three
## problems, and *"3 problems in your city — tap to review"* is the honest
## sentence for them. The summary inherits the group's worst severity so a
## collapsed P1 does not quietly become routine, and it keeps the deeplink of
## the most severe member so the tap still lands somewhere useful.
func _coalesce(candidates: Array[Dictionary], now_min: float) -> Array[Dictionary]:
	var runtime := _cfg.runtime()
	var min_count := AudioConfig.get_int(runtime, "coalesce_min_count", 0)
	var window := AudioConfig.get_num(runtime, "coalesce_window_minutes", 0.0)
	if min_count <= 1:
		return candidates.duplicate()
	var groups: Dictionary = {}
	for plan: Dictionary in candidates:
		var class_id := str(plan["class"])
		if not groups.has(class_id):
			groups[class_id] = ([] as Array[Dictionary])
		(groups[class_id] as Array[Dictionary]).append(plan)
	var out: Array[Dictionary] = []
	# Sorted, and by rank rather than by insertion: which class is summarised
	# first must not depend on which event happened to arrive first.
	for class_id: String in _cfg.class_ids():
		if not groups.has(class_id):
			continue
		var group: Array[Dictionary] = groups[class_id]
		var span := 0.0
		for plan: Dictionary in group:
			span = maxf(span, now_min - float(plan["at_min"]))
		if group.size() < min_count or span > window:
			out.append_array(group)
			continue
		out.append(_summary_for(group, class_id, now_min))
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a["seq"]) < int(b["seq"]))
	return out


func _summary_for(group: Array[Dictionary], class_id: String,
		now_min: float) -> Dictionary:
	var worst: Dictionary = group[0]
	for plan: Dictionary in group:
		if int(plan["severity"]) > int(worst["severity"]):
			worst = plan
	var notify_id := str(_cfg.runtime().get("coalesce_notify_id", "coalesced_summary"))
	var row := _cfg.event_def(notify_id)
	var members: Array = []
	for plan: Dictionary in group:
		members.append(str(plan["notify_id"]))
	members.sort()
	return {
		"seq": int(group[0]["seq"]),
		"notify_id": notify_id,
		"class": class_id,
		"in_app_class": _cfg.in_app_class(class_id),
		"severity": int(worst["severity"]),
		"aggregate": false,
		"cooldown_minutes": AudioConfig.get_num(row, "cooldown_minutes", 0.0),
		"channel_id": str(_cfg.class_def(class_id).get("channel_id", "")),
		"title_key": "n_%s_title" % notify_id,
		"body_key": "n_%s_body" % notify_id,
		"deeplink": str(row.get("deeplink", "report")),
		"key": notify_id,
		"ref": null,
		"event_type": "",
		"at_min": now_min,
		"count": group.size(),
		"coalesced": members,
	}


func _decide(plan: Dictionary, now_min: float, minute_of_day: int) -> Dictionary:
	var reason := _budget.request(str(plan["class"]), int(plan["severity"]),
			str(plan["key"]), float(plan["cooldown_minutes"]), now_min, minute_of_day)
	plan["decided_at_min"] = now_min
	plan["allowed"] = reason == NotificationBudget.REASON_OK
	plan["reason"] = reason
	plan["delivered"] = false
	if reason == NotificationBudget.REASON_QUIET_HOURS:
		# `defer_to_end`, not "drop": it comes back as one summary at 08:00.
		_deferred.append(plan)
	if bool(plan["allowed"]):
		plan["delivered"] = _sink.deliver(plan)
		notification_planned.emit(plan)
	else:
		notification_suppressed.emit(str(plan["key"]), reason)
	_plans.append(plan)
	return plan


## doc 08 §2.13.3's `defer_to_end`: everything quiet hours swallowed comes back
## as **one** P3 the moment the window closes. Detected from the transition
## rather than from a timer, so an app that was closed all night still reports
## the night on the first flush after 08:00.
func _release_quiet_hours(now_min: float, minute_of_day: int) -> Array[Dictionary]:
	var quiet := _budget.in_quiet_window(minute_of_day)
	var was := _was_quiet
	_was_quiet = quiet
	if not _quiet_seen:
		_quiet_seen = true
		return []
	if quiet or not was or _deferred.is_empty():
		return []
	var notify_id := str(_cfg.quiet_hours().get("summary_notify_id", "quiet_hours_summary"))
	var row := _cfg.event_def(notify_id)
	var class_id := str(row.get("class", "P3_routine"))
	var worst := 0
	for plan: Dictionary in _deferred:
		worst = maxi(worst, int(plan["severity"]))
	var count := _deferred.size()
	_deferred.clear()
	_seq += 1
	var summary := {
		"seq": _seq,
		"notify_id": notify_id,
		"class": class_id,
		"in_app_class": _cfg.in_app_class(class_id),
		"severity": worst,
		"aggregate": false,
		"cooldown_minutes": AudioConfig.get_num(row, "cooldown_minutes", 0.0),
		"channel_id": str(_cfg.class_def(class_id).get("channel_id", "")),
		"title_key": "n_%s_title" % notify_id,
		"body_key": "n_%s_body" % notify_id,
		"deeplink": str(row.get("deeplink", "report")),
		"key": notify_id,
		"ref": null,
		"event_type": "",
		"at_min": now_min,
		"count": count,
	}
	return [_decide(summary, now_min, minute_of_day)]


# ---------------------------------------------------------------------------
# Lifecycle — the two calls `game/android_lifecycle.gd` makes
# ---------------------------------------------------------------------------

## doc 08 §2.13's scheduling pass: run at `pause`/`quit`, when the process is
## about to stop existing and the fire times in the save are all anyone will
## have until it comes back.
func plan_for_background() -> Array[Dictionary]:
	return flush()


## …and its other half. *"On resume all pending alarms are cancelled and
## re-planned."* A notification that fired for an event that then did not happen
## is reconciled honestly in the report footer; one that has not fired yet is
## simply wrong by now, because the catch-up has replaced the future it assumed.
func replan_after_resume() -> int:
	var cancelled := _sink.cancel_all()
	_pending.clear()
	return cancelled


# ---------------------------------------------------------------------------
# Read side
# ---------------------------------------------------------------------------

func pending_count() -> int:
	return _pending.size()


func deferred_count() -> int:
	return _deferred.size()


## Every decision made, newest last.
func plans() -> Array[Dictionary]:
	return _plans.duplicate()


func allowed_count() -> int:
	var count := 0
	for plan: Dictionary in _plans:
		if bool(plan["allowed"]):
			count += 1
	return count


func suppressed_count() -> int:
	return _plans.size() - allowed_count()


func serialize() -> Dictionary:
	return {"section_version": 1, "budget": _budget.serialize()}


func deserialize(data: Dictionary) -> void:
	var raw: Variant = data.get("budget", {})
	if raw is Dictionary:
		_budget.deserialize(raw)


func _now_min() -> float:
	return float(wall_clock.call())


func _minute_of_day() -> int:
	return posmod(int(local_minute_of_day.call()), NotificationBudget.MINUTES_PER_DAY)
