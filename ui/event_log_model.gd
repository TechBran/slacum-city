class_name EventLogModel
extends RefCounted
## S13's feed (doc 12): the city's HISTORY, and the only screen that answers
## "what actually happened while I was looking somewhere else".
##
## The alerts centre (§2.15) and this are deliberately different objects with
## different jobs, sharing one ingest shape and one copy table:
##
##   * **Alerts** are a to-do list. Repeats coalesce into one row with a count,
##     rows are marked read, and the list is capped at 50 because a to-do list
##     nobody can finish is not a to-do list.
##   * **The log** is a ledger. Every event is its own line, in the order it
##     happened, newest first; nothing is coalesced, because the third
##     transformer trip is the interesting one; nothing is read or unread,
##     because history is not a task.
##
## Ingest is one call — `feed(event)` — taking a **sim bus event verbatim**, the
## same `SimEventBus.drain()` dictionaries `AlertsModel.feed()` takes, so the
## shell pipes one batch into both and nothing upstream knows either exists.
##
## Copy resolves the SAME `n_<notify_id>_title` / `n_<notify_id>_body` keys the
## alerts centre and doc 13's pushes use (G-8): a line in the log and the push
## that woke the player are the same sentence, forever. Which event is which
## category is `data/ui.json.event_log.events` — the one thing this table adds
## over `alerts.events`, and the whole filter strip.
##
## **Nothing here is persisted** (doc 12 §3.2 lists no feed in the `ui` save
## section, and this class has no `capture_state`). A resumed city starts its
## log at the resume, which is honest: the events it would otherwise "remember"
## were never in the save to begin with.
##
## Focus payloads work exactly like the alerts centre's: the caller injects a
## `locator` — `Callable(kind: StringName, id: Variant) -> Vector3` — because
## the sim's events carry ids and not metres, and a row the locator cannot
## place simply has no `Jump to it` affordance.

## `feed()` returns this when the event is not one the log records.
const NOT_LOGGED := {}

const CATEGORY_ALL := &"all"

const ARG_COUNT := "@count"
const ARG_TIME := "@time"
const ARG_ID := "@id"
const ARG_MONEY_PREFIX := "@money:"
## Resolves `ui_incident_kind_<value>` — doc 06 publishes `incident_type` as a
## snake_case id and a log row must never print one at the player.
const ARG_KIND_PREFIX := "@kind:"
## The general form: `@lookup:<string_key_prefix>:<payload_key>` resolves
## `<prefix><value lowercased>` from the string table. Doc 07 publishes its
## weather as `HEAVY_RAIN`; a sentence that says "Weather turned to HEAVY_RAIN"
## is a sentence written by a machine for a machine.
const ARG_LOOKUP_PREFIX := "@lookup:"
## Log rows quote a magnitude, not a measurement: doc 06's `response_min` is a
## float that carries fourteen digits of solver noise, and "cleared it in
## 7.93333333333333 minutes" is not a sentence anybody wrote.
const NUMBER_SNAP := 0.1

const MINUTES_PER_DAY := 1440
const MINUTES_PER_HOUR := 60

const _DEFAULT_MAX_ENTRIES := 200
const _DEFAULT_RECENT_MIN := 2
const _DEFAULT_CATEGORIES := ["all", "power", "water", "incidents", "economy", "weather"]
## Locator kinds the shell's `_alert_world_pos` actually resolves. A `zone` or
## an `edge` is a real key for coalescing and a useless one for a camera jump,
## so it is never offered as one.
##
## `cell` is doc 07 §2.4's FLOOD cell — `"B<bx>,<bz>"` for a land block,
## `"<tx>,<tz>"` for a tile (`FloodField.block_key_of` / `key_of`). It is here
## because a flooded street is the one thing in the weather category a player
## would want to jump to; a shell whose locator does not yet know the shape
## returns null and the row simply carries no `Jump to it`, which is this
## model's standing rule and not a special case for floods.
const FOCUSABLE_KINDS := ["tile", "block_id", "building", "cell"]

var _cfg: UIConfig
var _log: Dictionary = {}
var _state_glyphs: Dictionary = {}
var _rules: Array = []

var _entries: Array[Dictionary] = []   ## oldest first; `entries()` reverses
var _seq := 0
var _minute_of_day := 0
var _day_index := 0
var _filter: StringName = CATEGORY_ALL
var _locator := Callable()


func _init(cfg: UIConfig = null) -> void:
	if cfg == null:
		return
	_cfg = cfg
	_log = cfg.section("event_log")
	_state_glyphs = cfg.section("state_glyphs")
	var raw: Variant = _log.get("events", [])
	_rules = raw if raw is Array else []


static func load_from_files() -> EventLogModel:
	return EventLogModel.new(UIConfig.load_from_files())


## `Callable(kind: StringName, id: Variant) -> Variant` returning a `Vector3`
## (anything else reads as "no position"). The same Callable the alerts centre
## takes, so one shell function serves both.
func set_locator(locator: Callable) -> void:
	_locator = locator


## Sim time for `{time}` placeholders, row stamps and the relative ages. Called
## once per drain; the model never reads a clock itself.
func set_clock(minute_of_day: int, day_index: int = 0) -> void:
	_minute_of_day = minute_of_day
	_day_index = day_index


# ---------------------------------------------------------------------------
# Ingest
# ---------------------------------------------------------------------------

## One sim event in, one log row out (or `{}` when the event is not one the log
## records). The returned row is the live entry, not a copy.
func feed(event: Dictionary) -> Dictionary:
	var rule := rule_for(event)
	if rule.is_empty():
		return NOT_LOGGED
	var notify_id := str(rule.get("notify_id", ""))
	if notify_id == "":
		return NOT_LOGGED
	var key_name := str(rule.get("key", ""))
	var key_value: Variant = event.get(key_name, null) if key_name != "" else null

	_seq += 1
	var entry := {
		"id": "log_%d" % _seq,
		"seq": _seq,
		"event_type": str(event.get("type", "")),
		"notify_id": notify_id,
		"category": StringName(str(rule.get("category", CATEGORY_ALL))),
		"state": StringName(str(rule.get("state", String(HudModel.STATE_NORMAL)))),
		"entity_kind": key_name,
		"entity_id": key_value,
		"payload": event.duplicate(true),
		"at_minute": _minute_of_day,
		"day_index": _day_index,
		"world_pos": Vector3.ZERO,
		"has_focus": false,
		"title": "",
		"body": "",
		"glyph": "",
	}
	_resolve_focus(entry, event, key_name, key_value)
	_render(entry, rule)
	_entries.append(entry)
	# The cap drops the OLDEST line, never the newest: a log that forgets what
	# just happened to keep something from last week is not a log.
	var cap := maxi(1, UIConfig.get_int(_log, "max_entries", _DEFAULT_MAX_ENTRIES))
	while _entries.size() > cap:
		_entries.remove_at(0)
	return entry


## Drain-shaped ingest: hand it `SimEventBus.drain()` and get back only the rows
## it recorded, oldest first.
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
		if not EventLogModel._matches(rule.get("match", {}), event):
			continue
		return rule
	return {}


## `match` is an AND over literal payload values. JSON has one number type, so
## bools and numbers compare by value and never by type.
static func _matches(raw_match: Variant, event: Dictionary) -> bool:
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


func _resolve_focus(entry: Dictionary, event: Dictionary, key_name: String,
		key_value: Variant) -> void:
	var world: Variant = event.get("world_pos", event.get("pos", null))
	if not (world is Vector3) and _locator.is_valid() and key_value != null \
			and FOCUSABLE_KINDS.has(key_name):
		world = _locator.call(StringName(key_name), EventLogModel.as_tile(key_value)
				if key_name == "tile" else key_value)
	if world is Vector3:
		entry["world_pos"] = world
		entry["has_focus"] = true


## Doc 06 publishes a tile as `[x, y]` and doc 10 as a `Vector2i`; the locator
## contract is `(&"tile", Vector2i)`, so the conversion happens once, here.
static func as_tile(value: Variant) -> Variant:
	if value is Vector2i:
		return value
	if value is Array and (value as Array).size() >= 2:
		return Vector2i(int((value as Array)[0]), int((value as Array)[1]))
	return value


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
			out[name] = 1
		elif source == ARG_TIME:
			out[name] = HudModel.clock_hhmm(int(entry["at_minute"]))
		elif source == ARG_ID:
			if entry["entity_id"] != null:
				out[name] = str(entry["entity_id"])
		elif source.begins_with(ARG_MONEY_PREFIX):
			var money_key := source.substr(ARG_MONEY_PREFIX.length())
			if payload.has(money_key):
				out[name] = HudModel.money(int(payload[money_key]))
		elif source.begins_with(ARG_KIND_PREFIX):
			var kind_key := source.substr(ARG_KIND_PREFIX.length())
			if payload.has(kind_key):
				out[name] = _incident_kind(str(payload[kind_key]))
		elif source.begins_with(ARG_LOOKUP_PREFIX):
			var spec_parts := source.substr(ARG_LOOKUP_PREFIX.length()).split(":", true, 1)
			if spec_parts.size() == 2 and payload.has(spec_parts[1]):
				out[name] = _lookup(spec_parts[0], str(payload[spec_parts[1]]))
		elif payload.has(source):
			out[name] = _plain(payload[source])
	return out


## `<prefix><value lowercased>` from the string table, falling back to the raw
## value — a missing key must cost the row its polish, never its meaning.
func _lookup(key_prefix: String, value: String) -> String:
	if _cfg == null:
		return value
	var key := key_prefix + value.to_lower()
	return _cfg.t(key) if _cfg.has_string(key) else value


## `ui_incident_kind_<type>` — the same key the incident drawer resolves, so a
## structure fire is called the same thing in both screens.
func _incident_kind(type_id: String) -> String:
	if _cfg == null:
		return type_id
	var key := "ui_incident_kind_%s" % type_id
	if _cfg.has_string(key):
		return _cfg.t(key)
	return _cfg.t("ui_incident_kind_unknown") if _cfg.has_string("ui_incident_kind_unknown") \
			else type_id


## A float is snapped to one decimal and then printed as an integer if it lands
## on one: `Tier 4`, never `Tier 4.0`; `7.9 minutes`, never `7.93333333333333`.
static func _plain(value: Variant) -> Variant:
	if not (value is float):
		return value
	var snapped := snappedf(float(value), NUMBER_SNAP)
	if is_equal_approx(snapped, round(snapped)):
		return int(round(snapped))
	return snapped


## `data/strings.en.json` with `{named}` substitution, then the hole rule: a
## sentence still carrying an unresolved placeholder is dropped rather than
## shown. A missing key yields "" rather than the raw key — a log row is not the
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
# Filter chips
# ---------------------------------------------------------------------------

## `data/ui.json.event_log.categories`, `all` first.
func categories() -> Array[StringName]:
	var raw: Variant = _log.get("categories", _DEFAULT_CATEGORIES)
	var source: Array = raw if raw is Array else _DEFAULT_CATEGORIES
	var out: Array[StringName] = []
	for value: Variant in source:
		out.append(StringName(str(value)))
	return out if not out.is_empty() else ([CATEGORY_ALL] as Array[StringName])


static func category_label_key(category: StringName) -> String:
	return "ui_event_log_cat_%s" % String(category)


func filter() -> StringName:
	return _filter


## Selecting the live filter again returns to `all`, the same "one chip is both
## the on and the off switch" gesture §2.5's overlay chips use.
func set_filter(category: StringName) -> StringName:
	if not categories().has(category):
		return _filter
	_filter = CATEGORY_ALL if category == _filter and category != CATEGORY_ALL else category
	return _filter


## One row per chip: `{id, label_key, selected, count}`. `count` is how many
## rows that chip would show right now, so an empty category is visibly empty
## instead of a chip that leads to a blank list.
func chips() -> Array[Dictionary]:
	var counts: Dictionary = {}
	for row: Dictionary in _entries:
		var category: StringName = row["category"]
		counts[category] = int(counts.get(category, 0)) + 1
	var out: Array[Dictionary] = []
	for category: StringName in categories():
		out.append({
			"id": category,
			"label_key": EventLogModel.category_label_key(category),
			"selected": category == _filter,
			"count": _entries.size() if category == CATEGORY_ALL \
					else int(counts.get(category, 0)),
		})
	return out


# ---------------------------------------------------------------------------
# Read side
# ---------------------------------------------------------------------------

## Newest first — the order the list renders — filtered by the live chip.
## `limit <= 0` means everything.
func entries(limit: int = 0) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for i in range(_entries.size() - 1, -1, -1):
		var row: Dictionary = _entries[i]
		if _filter != CATEGORY_ALL and row["category"] != _filter:
			continue
		var copy := row.duplicate(true)
		copy["age_text"] = relative_time(row)
		out.append(copy)
		if limit > 0 and out.size() >= limit:
			break
	return out


func entry(log_id: String) -> Dictionary:
	for row: Dictionary in _entries:
		if str(row["id"]) == log_id:
			var copy := row.duplicate(true)
			copy["age_text"] = relative_time(row)
			return copy
	return {}


## Every row, filter ignored — what the count in the header says.
func size() -> int:
	return _entries.size()


func visible_count() -> int:
	return entries().size()


func clear() -> void:
	_entries.clear()


# ---------------------------------------------------------------------------
# Relative timestamps
# ---------------------------------------------------------------------------

## Game-minutes between a row and the clock the model was last given. Never
## negative: a row stamped in the future (a save loaded backwards, a clock the
## shell has not pushed yet) reads as `just now` rather than as `-3 min ago`.
func age_minutes(row: Dictionary) -> int:
	var then := int(row.get("day_index", 0)) * MINUTES_PER_DAY \
			+ int(row.get("at_minute", 0))
	var now := _day_index * MINUTES_PER_DAY + _minute_of_day
	return maxi(0, now - then)


## `just now` · `12 min ago` · `3 h ago` · `2 d ago`. The thresholds are the
## natural ones and the copy is `data/strings.en.json`'s; nothing is authored
## here.
func relative_time(row: Dictionary) -> String:
	var minutes := age_minutes(row)
	var recent := UIConfig.get_int(_log, "recent_minutes", _DEFAULT_RECENT_MIN)
	if minutes < maxi(0, recent):
		return _t("ui_event_log_now", {})
	if minutes < MINUTES_PER_HOUR:
		return _t("ui_event_log_ago_min", {"n": minutes})
	if minutes < MINUTES_PER_DAY:
		return _t("ui_event_log_ago_h", {"n": minutes / MINUTES_PER_HOUR})
	return _t("ui_event_log_ago_d", {"n": minutes / MINUTES_PER_DAY})


func _t(key: String, args: Dictionary) -> String:
	return _cfg.t(key, args) if _cfg != null and _cfg.has_string(key) else ""


# ---------------------------------------------------------------------------
# Tap-to-focus
# ---------------------------------------------------------------------------

## What the view needs to emit `focus_requested(world_pos)`. Unlike the alerts
## centre this does NOT mutate the row: a log line has no read state, and
## looking at history does not change it.
func focus_payload(log_id: String) -> Dictionary:
	for row: Dictionary in _entries:
		if str(row["id"]) != log_id:
			continue
		return {
			"id": log_id,
			"has_focus": bool(row["has_focus"]),
			"world_pos": row["world_pos"],
			"entity_kind": str(row["entity_kind"]),
			"entity_id": row["entity_id"],
			"event_type": str(row["event_type"]),
			"notify_id": str(row["notify_id"]),
		}
	return {}
