class_name NotificationConfig
extends RefCounted
## The single reader for `data/notifications.json` (doc 08 §2.13, §3.3).
##
## `UIConfig` / `AudioConfig`-shaped on purpose: parsing is handed a Dictionary,
## so everything downstream is constructible from a fixture with no file IO, and
## `tests/test_notifications.gd` never touches the disk to try a budget.
##
## The file has four sections and they belong to different readers:
##
##   * `classes` — the four priority classes, their Android channels and their
##     **push** budgets. `NotificationBudget` and doc 13's future sink.
##   * `events` — one row per notify_id: class, severity, per-key cooldown,
##     deeplink, and the doc-12 state token the in-app row wears.
##   * `bindings` — an ORDERED list mapping a sim event onto a notify_id. Order
##     is the priority order and first match wins, which is why it is an array
##     while `events` is an object.
##   * `runtime` — the global bucket, coalescing and quiet hours.
##
## `ui/alerts_model.gd` reads `bindings` + `events`; the router reads
## `classes` + `events` + `runtime`. Neither can disagree with the other about
## what class an event is, because there is one answer in one file.

const NOTIFICATIONS_JSON_PATH := "res://data/notifications.json"

## Class rank is the ordering the whole system uses — doc 06's
## `offline_notify_min_priority` is the same scale, which is what lets one
## threshold control the digest and the alarms together.
const RANK_UNKNOWN := 99

var errors: PackedStringArray = []

var _data: Dictionary = {}
var _alert_rules: Array = []


func _init(data: Dictionary = {}) -> void:
	_data = data


static func load_from_files(path: String = NOTIFICATIONS_JSON_PATH) -> NotificationConfig:
	var cfg := NotificationConfig.new()
	if not FileAccess.file_exists(path):
		cfg.errors.append("missing %s" % path)
		return cfg
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		cfg.errors.append("cannot parse %s" % path)
		return cfg
	cfg._data = parsed
	return cfg


func is_valid() -> bool:
	return errors.is_empty()


func data() -> Dictionary:
	return _data


func section(name: String) -> Dictionary:
	var value: Variant = _data.get(name, {})
	return value if value is Dictionary else {}


func classes() -> Dictionary:
	return section("classes")


func events() -> Dictionary:
	return section("events")


func runtime() -> Dictionary:
	return section("runtime")


## The platform block — ids, the Doze feasibility guard, channel-name keys and
## the offline predictability map. Doc 13's, and the only part of this file that
## is not doc 08's (report C-71 splits policy from platform, not file from file).
func delivery() -> Dictionary:
	return section("delivery")


func quiet_hours() -> Dictionary:
	var value: Variant = runtime().get("quiet_hours", {})
	return value if value is Dictionary else {}


## Class ids in rank order — the order a summary picks its own class in, and the
## order a listing is shown in. Never dictionary order: a reformatted file must
## not change which class wins a tie.
func class_ids() -> Array[String]:
	var out: Array[String] = []
	for key: Variant in classes():
		if str(key).begins_with("_"):
			continue
		out.append(str(key))
	out.sort_custom(func(a: String, b: String) -> bool:
		var ra := class_rank(a)
		var rb := class_rank(b)
		return a < b if ra == rb else ra < rb)
	return out


func class_def(class_id: String) -> Dictionary:
	var value: Variant = classes().get(class_id, {})
	return value if value is Dictionary else {}


func class_rank(class_id: String) -> int:
	return AudioConfig.get_int(class_def(class_id), "rank", RANK_UNKNOWN)


## A class that ships disabled emits nothing at all — P4 in MVP (report C-71).
func class_enabled(class_id: String) -> bool:
	var row := class_def(class_id)
	if row.is_empty():
		return false
	return bool(row.get("mvp_enabled", true)) and bool(row.get("default_enabled", true))


## doc 12's p1/p2/p3 key for the in-app banner gate. One-way: doc 12's own
## `in_app_alerts` block keys off these and must never be read to decide a push.
func in_app_class(class_id: String) -> String:
	return str(class_def(class_id).get("in_app_class", "p3"))


func event_ids() -> Array[String]:
	var out: Array[String] = []
	for key: Variant in events():
		if str(key).begins_with("_"):
			continue
		out.append(str(key))
	out.sort()
	return out


func event_def(notify_id: String) -> Dictionary:
	var value: Variant = events().get(notify_id, {})
	return value if value is Dictionary else {}


## An event the sim never emits: the coalescing summary, the quiet-hours summary
## and the two P4 rows. They have no binding and are synthesised by the router.
func event_is_synthetic(notify_id: String) -> bool:
	return bool(event_def(notify_id).get("synthetic", false))


## The `bindings` array with `_comment` entries stripped — a binding without a
## `type` is documentation, and the matcher should never have to know that.
func bindings() -> Array:
	var out: Array = []
	var raw: Variant = _data.get("bindings", [])
	if not (raw is Array):
		return out
	for entry: Variant in raw:
		if entry is Dictionary and str((entry as Dictionary).get("type", "")) != "":
			out.append(entry)
	return out


## `{"match": {"block_dark": true}}` against a payload — exact equality, JSON
## number-aware. JSON has one number type, so bools and numbers compare by value
## and not by type; `ui/alerts_model.gd` carries the identical rule for the
## identical reason, and this copy exists so `game/` never has to reach up into
## `ui/` to classify an event (constitution §3's dependency direction).
static func matches(raw_match: Variant, event: Dictionary) -> bool:
	if not (raw_match is Dictionary):
		return true
	for key: String in (raw_match as Dictionary):
		var wanted: Variant = (raw_match as Dictionary)[key]
		if not event.has(key):
			return false
		var actual: Variant = event[key]
		if wanted is bool or actual is bool:
			if bool(actual) != bool(wanted):
				return false
		elif (wanted is float or wanted is int) and (actual is float or actual is int):
			if not is_equal_approx(float(actual), float(wanted)):
				return false
		elif str(actual) != str(wanted):
			return false
	return true


## What `ui/alerts_model.gd` ingests: each binding merged with the `class` and
## `state` of the event row it names, so the model keeps taking one flat rule
## dictionary and its `feed()` is untouched by where the table now lives.
##
## A binding may override `class` (an incident carries its own urgency in
## `notification_priority`); the event row supplies everything else, so there is
## still exactly one place a severity or a cooldown is written down.
func alert_rules() -> Array:
	# Built once. The table is shared process-wide (see
	# `AlertsModel.notification_table`), and re-deriving it per model would both
	# re-do the merge and append the same load errors again and again.
	if not _alert_rules.is_empty():
		return _alert_rules
	var out: Array = []
	for raw: Variant in bindings():
		var binding: Dictionary = raw
		var notify_id := str(binding.get("notify_id", ""))
		if notify_id == "":
			continue
		var event := event_def(notify_id)
		if event.is_empty():
			errors.append("binding for %s names an unknown notify_id '%s'"
					% [str(binding.get("type", "")), notify_id])
			continue
		var class_id := str(binding.get("class", event.get("class", "P3_routine")))
		var rule := binding.duplicate(true)
		rule["push_class"] = class_id
		rule["class"] = in_app_class(class_id)
		rule["state"] = str(event.get("state", "normal"))
		rule["severity"] = AudioConfig.get_int(event, "severity", 0)
		out.append(rule)
	_alert_rules = out
	return _alert_rules
