class_name AlertsModel
extends RefCounted
## The alerts centre's feed (doc 12 §2.15, §4.5): the persistent list behind the
## banner stack, and the only place a raw sim event becomes player-facing copy.
##
## Ingest is one call — `feed(event)` — taking a **sim bus event verbatim**
## (`sim/core/event_bus.gd` dictionaries: a `type` plus that system's payload).
## The lead engineer pipes `SimHost.ticked` straight into `feed_batch()`; nothing
## upstream has to know this class exists, and this class never holds a sim
## reference, so it stays headless.
##
## Which event becomes which notification is **data**, and as of 2026-08-19 that
## data is **`data/notifications.json`** — doc 08's file, owned solely by doc 08
## (report C-71). The stand-in list in `data/ui.json.alerts.events` was deleted
## wholesale, as that block's own comment always said it would be; `ui.json`
## keeps presentation (row height, panel width, badge cap) and doc 12's
## foreground `in_app_alerts` gate, and nothing else about alerts.
##
## Only the *source* changed. `NotificationConfig.alert_rules()` hands back the
## same flat rule shape this class has always matched on — a binding merged with
## its event row's class and state — so `feed()` below is untouched, and the one
## thing that is now impossible is the in-app feed and a push disagreeing about
## what class an event is.
##
## Copy is data too: every row resolves `n_<notify_id>_title` /
## `n_<notify_id>_body` from `data/strings.en.json`, the same keys doc 13
## renders for a push, so an in-app row and its push can never drift (G-8).
## Nothing in this file is authored English.
##
## Two behaviours worth naming:
##   * **Coalescing.** A repeat of an alert the player has not read yet
##     increments that row's `count` instead of stacking a duplicate — which is
##     what makes `{count} blocks are dark` say `3` rather than filling the list
##     with three identical rows. `coalesce_by` picks the identity: `notify_id`
##     (all dark blocks are one story) or `key` (each transformer is its own).
##   * **Holes are never printed.** A body sentence whose data the sim did not
##     supply is dropped rather than rendered with a `{placeholder}` in it.
##
## Focus payloads carry a world position so the view can emit
## `focus_requested(world_pos)`. The sim's events carry ids, not metres, so the
## caller injects a `locator` — `Callable(kind: StringName, id: Variant)`
## returning a `Vector3` — and an alert with no resolvable position simply has no
## `Jump to it` affordance.

## `feed()` returns this when the event is not notifiable — an empty Dictionary,
## so `if not result.is_empty()` is the whole contract.
const NOT_NOTIFIABLE := {}

const ARG_COUNT := "@count"
const ARG_TIME := "@time"
const ARG_ID := "@id"
const ARG_MONEY_PREFIX := "@money:"
## A sim quantity that is a float and a *reading*: thousands-grouped, no decimal
## tail. Without it `shed_kw` reached the table as `1840.0` and the banner read
## `1840.0 kW dropped` — a float's `str()`, not a number a player recognises.
const ARG_NUMBER_PREFIX := "@number:"

const COALESCE_NOTIFY_ID := "notify_id"
const COALESCE_KEY := "key"

const _DEFAULT_MAX_ENTRIES := 50
const _DEFAULT_BADGE_MAX := 99

var _cfg: UIConfig
var _notifications: NotificationConfig
var _alerts: Dictionary = {}
var _state_glyphs: Dictionary = {}
var _rules: Array = []

var _entries: Array[Dictionary] = []   ## newest last; `entries()` reverses
var _seq := 0
var _minute_of_day := 0
var _day_index := 0
var _locator := Callable()


## `notifications` is doc 08's table. Left null it is loaded from
## `data/notifications.json` once per process and shared — the file is a few
## kilobytes of rules that never change at runtime, and every screen that builds
## an `AlertsModel` (the alerts centre, `tools/ui_preview.gd`, a test) would
## otherwise re-parse it. Pass one explicitly to drive the model off a fixture.
func _init(cfg: UIConfig = null, notifications: NotificationConfig = null) -> void:
	if cfg == null:
		return
	_cfg = cfg
	_notifications = notifications if notifications != null else AlertsModel.notification_table()
	_alerts = cfg.section("alerts")
	_state_glyphs = cfg.section("state_glyphs")
	_rules = _notifications.alert_rules()


static var _shared_notifications: NotificationConfig = null


## The process-wide notification table. `reload_notification_table()` exists for
## a test that wants the file re-read after editing it, and for nothing else.
static func notification_table() -> NotificationConfig:
	if _shared_notifications == null:
		_shared_notifications = NotificationConfig.load_from_files()
	return _shared_notifications


static func reload_notification_table() -> NotificationConfig:
	_shared_notifications = null
	return notification_table()


static func load_from_files() -> AlertsModel:
	return AlertsModel.new(UIConfig.load_from_files())


## Non-fatal load problems from `data/notifications.json` — a binding naming an
## unknown notify_id, a missing file. Empty is the healthy answer, and
## `tests/test_notifications.gd` is where it becomes loud.
func notification_errors() -> PackedStringArray:
	return _notifications.errors if _notifications != null else PackedStringArray()


func notifications() -> NotificationConfig:
	return _notifications


## `Callable(kind: StringName, id: Variant) -> Variant` returning a `Vector3`
## (anything else reads as "no position"). Injected by the shell, which is the
## only layer that knows where a block or a building sits in metres.
func set_locator(locator: Callable) -> void:
	_locator = locator


## Sim time for `{time}` placeholders and row timestamps. Called once per drain;
## the model never reads a clock itself.
func set_clock(minute_of_day: int, day_index: int = 0) -> void:
	_minute_of_day = minute_of_day
	_day_index = day_index


# ---------------------------------------------------------------------------
# Ingest
# ---------------------------------------------------------------------------

## One sim event in, one feed row out (or `{}` when the event is not one the
## player is told about). The returned row is the live entry, not a copy.
func feed(event: Dictionary) -> Dictionary:
	var rule := rule_for(event)
	if rule.is_empty():
		return NOT_NOTIFIABLE
	var notify_id := str(rule.get("notify_id", ""))
	if notify_id == "":
		return NOT_NOTIFIABLE
	var key_name := str(rule.get("key", ""))
	var key_value: Variant = event.get(key_name, null) if key_name != "" else null
	var identity := _identity(rule, notify_id, key_value)

	var existing := _find_unread(identity)
	if not existing.is_empty():
		existing["count"] = int(existing["count"]) + 1
		existing["at_minute"] = _minute_of_day
		existing["day_index"] = _day_index
		existing["payload"] = event.duplicate(true)
		if key_value != null:
			existing["entity_id"] = key_value
		_resolve_focus(existing, event, key_name, key_value)
		_render(existing, rule)
		return existing

	_seq += 1
	var entry := {
		"id": "alert_%d" % _seq,
		"seq": _seq,
		"identity": identity,
		"event_type": str(event.get("type", "")),
		"notify_id": notify_id,
		# `class` is doc 12's surface key (p1/p2/p3, `data/ui.json.in_app_alerts`);
		# `push_class` is doc 08's own name for the same decision. Both, because
		# they are two budgets and a row that only carried one of them would be
		# the exact confusion report C-72 exists to prevent.
		"class": str(rule.get("class", "p3")),
		"push_class": str(rule.get("push_class", "P3_routine")),
		"severity": int(rule.get("severity", 0)),
		"state": StringName(str(rule.get("state", String(HudModel.STATE_NORMAL)))),
		"entity_kind": key_name,
		"entity_id": key_value,
		"payload": event.duplicate(true),
		"at_minute": _minute_of_day,
		"day_index": _day_index,
		"count": 1,
		"read": false,
		"world_pos": Vector3.ZERO,
		"has_focus": false,
		"title": "",
		"body": "",
		"glyph": "",
	}
	_resolve_focus(entry, event, key_name, key_value)
	_render(entry, rule)
	_entries.append(entry)
	var cap := UIConfig.get_int(_alerts, "max_entries", _DEFAULT_MAX_ENTRIES)
	while _entries.size() > maxi(1, cap):
		_entries.remove_at(0)
	return entry


## Drain-shaped ingest: hand it `SimEventBus.drain()` and get back only the rows
## that were actually created or updated, newest last.
func feed_batch(events: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw: Variant in events:
		if not (raw is Dictionary):
			continue
		var entry := feed(raw)
		if not entry.is_empty():
			out.append(entry)
	return out


## First matching rule wins, so `data/ui.json` orders the two `BlockDarkChanged`
## rules (dark / restored) and the more specific one sits first.
func rule_for(event: Dictionary) -> Dictionary:
	var type_name := str(event.get("type", ""))
	if type_name == "":
		return {}
	for raw: Variant in _rules:
		if not (raw is Dictionary):
			continue
		var rule: Dictionary = raw
		if str(rule.get("type", "")) != type_name:
			continue
		if not _matches(rule.get("match", {}), event):
			continue
		return rule
	return {}


static func _matches(raw_match: Variant, event: Dictionary) -> bool:
	if not (raw_match is Dictionary):
		return true
	for key: String in (raw_match as Dictionary):
		var wanted: Variant = (raw_match as Dictionary)[key]
		if not event.has(key):
			return false
		var actual: Variant = event[key]
		# JSON has one number type; compare bools and numbers by value, not type.
		if wanted is bool or actual is bool:
			if bool(actual) != bool(wanted):
				return false
		elif (wanted is float or wanted is int) and (actual is float or actual is int):
			if not is_equal_approx(float(actual), float(wanted)):
				return false
		elif str(actual) != str(wanted):
			return false
	return true


func _identity(rule: Dictionary, notify_id: String, key_value: Variant) -> String:
	var mode := str(rule.get("coalesce_by",
			COALESCE_KEY if rule.has("key") else COALESCE_NOTIFY_ID))
	if mode == COALESCE_KEY and key_value != null:
		return "%s/%s" % [notify_id, str(key_value)]
	return notify_id


func _find_unread(identity: String) -> Dictionary:
	for i in range(_entries.size() - 1, -1, -1):
		var entry: Dictionary = _entries[i]
		if bool(entry["read"]):
			continue
		if str(entry["identity"]) == identity:
			return entry
	return {}


func _resolve_focus(entry: Dictionary, event: Dictionary, key_name: String,
		key_value: Variant) -> void:
	var world: Variant = event.get("world_pos", event.get("pos", null))
	if not (world is Vector3) and _locator.is_valid() and key_name != "" and key_value != null:
		world = _locator.call(StringName(key_name), key_value)
	if world is Vector3:
		entry["world_pos"] = world
		entry["has_focus"] = true
	elif not bool(entry.get("has_focus", false)):
		entry["world_pos"] = Vector3.ZERO
		entry["has_focus"] = false


# ---------------------------------------------------------------------------
# Copy (G-8) — `n_<notify_id>_title` / `n_<notify_id>_body`
# ---------------------------------------------------------------------------

func _render(entry: Dictionary, rule: Dictionary) -> void:
	var notify_id := str(entry["notify_id"])
	var args := _args(entry, rule)
	entry["title_key"] = "n_%s_title" % notify_id
	entry["body_key"] = "n_%s_body" % notify_id
	entry["title"] = _format(str(entry["title_key"]), args)
	entry["body"] = _format(str(entry["body_key"]), args)
	entry["glyph"] = state_glyph(entry["state"])


func _args(entry: Dictionary, rule: Dictionary) -> Dictionary:
	var spec: Variant = rule.get("args", {})
	var out: Dictionary = {}
	if not (spec is Dictionary):
		return out
	var payload: Dictionary = entry["payload"]
	for name: String in (spec as Dictionary):
		var source := str((spec as Dictionary)[name])
		if source == ARG_COUNT:
			out[name] = int(entry["count"])
		elif source == ARG_TIME:
			out[name] = HudModel.clock_hhmm(int(entry["at_minute"]))
		elif source == ARG_ID:
			if entry["entity_id"] != null:
				out[name] = str(entry["entity_id"])
		elif source.begins_with(ARG_MONEY_PREFIX):
			var money_key := source.substr(ARG_MONEY_PREFIX.length())
			if payload.has(money_key):
				out[name] = HudModel.money(int(payload[money_key]))
		elif source.begins_with(ARG_NUMBER_PREFIX):
			var number_key := source.substr(ARG_NUMBER_PREFIX.length())
			if payload.has(number_key):
				out[name] = HudModel.pop(int(round(float(payload[number_key]))))
		elif payload.has(source):
			out[name] = payload[source]
	return out


## `data/strings.en.json` with `{named}` substitution, then the hole rule: a
## sentence still carrying an unresolved placeholder is dropped rather than
## shown. A missing key yields "" rather than the raw key — a feed row is not the
## place to shout about a copy bug (doc 12 test 21 is).
func _format(key: String, args: Dictionary) -> String:
	if _cfg == null or not _cfg.has_string(key):
		return ""
	var text := _cfg.t(key, args)
	if not text.contains("{"):
		return text
	var kept: PackedStringArray = []
	for sentence: String in text.split(". ", false):
		if sentence.contains("{"):
			continue
		kept.append(sentence)
	var joined := ". ".join(kept).strip_edges()
	if joined == "":
		return ""
	return joined if joined.ends_with(".") else joined + "."


func state_glyph(state: StringName) -> String:
	var glyph_name := str(_state_glyphs.get(String(state), ""))
	return str(HudModel.STATE_GLYPH_CHARS.get(glyph_name, ""))


# ---------------------------------------------------------------------------
# Read side
# ---------------------------------------------------------------------------

## Newest first — the order the list renders. `limit <= 0` means everything.
func entries(limit: int = 0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(_entries.size() - 1, -1, -1):
		out.append((_entries[i] as Dictionary).duplicate(true))
		if limit > 0 and out.size() >= limit:
			break
	return out


func entry(alert_id: String) -> Dictionary:
	for row: Dictionary in _entries:
		if str(row["id"]) == alert_id:
			return row.duplicate(true)
	return {}


func size() -> int:
	return _entries.size()


func unread_count() -> int:
	var count := 0
	for row: Dictionary in _entries:
		if not bool(row["read"]):
			count += 1
	return count


## Chip badge copy: "" when there is nothing unread, else the count, capped at
## `unread_badge_max` with a `+` so the chip never grows past its 48 dp target.
func badge_text() -> String:
	var count := unread_count()
	if count <= 0:
		return ""
	var cap := UIConfig.get_int(_alerts, "unread_badge_max", _DEFAULT_BADGE_MAX)
	return "%d+" % cap if count > cap else str(count)


func mark_read(alert_id: String) -> bool:
	for row: Dictionary in _entries:
		if str(row["id"]) != alert_id:
			continue
		if bool(row["read"]):
			return false
		row["read"] = true
		return true
	return false


func mark_all_read() -> int:
	var changed := 0
	for row: Dictionary in _entries:
		if not bool(row["read"]):
			row["read"] = true
			changed += 1
	return changed


func clear() -> void:
	_entries.clear()


## What the view needs to emit `focus_requested(world_pos)`. Tapping a row is
## also what marks it read, so that is folded in here — the two are one gesture.
func focus_payload(alert_id: String) -> Dictionary:
	for row: Dictionary in _entries:
		if str(row["id"]) != alert_id:
			continue
		row["read"] = true
		return {
			"id": alert_id,
			"has_focus": bool(row["has_focus"]),
			"world_pos": row["world_pos"],
			"entity_kind": str(row["entity_kind"]),
			"entity_id": row["entity_id"],
			"event_type": str(row["event_type"]),
			"notify_id": str(row["notify_id"]),
		}
	return {}
