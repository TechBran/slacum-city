class_name GoalSystem
extends RefCounted
## The teaching curriculum (doc 09 §2.14): per-city-level objective lists,
## evaluated from the sim's own event stream and a per-hour state reading.
##
## **Why this exists.** Doc 09 §2.11's ladder is a population threshold and
## nothing else, and a threshold is not a goal: the player was told "Level 2"
## by a toast and never told what Level 3 costs, so the ladder was invisible and
## the first hour of the game had no arc past the eleven-step tutorial. This
## system is the arc — five levels of objectives, each teaching one system in
## play order, each stating exactly what it wants and how far along it is.
##
## **The one rule that keeps the ladder honest.** Objectives ADVANCE the level;
## they do not gate it. `city_level = max(population_ladder, objectives_earned)`
## — the population threshold stays underneath as a backstop, so a player who
## ignores the goals sheet still progresses on the curve doc 92 §19 fitted, and
## an agent that never learns a verb (every strategy in `tools/playtest.gd`)
## measures the same ladder it always did. See doc 93 §G1 for the ruling.
##
## **Cost.** Evaluation is O(events), never O(buildings): the event kinds
## subscribe through `SimEventBus.observer` and only the ACTIVE level's five-odd
## objectives are consulted per event. The state kinds (population, happiness…)
## are read once a game-hour by [reconcile], off scalars the sim already has.
##
## Deterministic by construction: no RNG, no clock, no wall time. Everything it
## remembers is in [serialize].

## Doc 09 §8.3's file. Read once per process and cached — it is authored data
## and it cannot change while the game runs.
const DATA_PATH := "res://data/goals.json"

# --------------------------------------------------------------- objective kinds

## Kinds that COUNT EVENTS. `event` is the bus type; `match_key`/`match_field`
## pair the objective's own field against a payload field (empty means "any");
## `amount` names a payload field carrying a count (empty means "one per event").
##
## Every one of these is a verb the player performs, so the counter ticks on the
## COMMAND, not on the thing finishing: "Build 4 houses" ticks when the fourth
## house is committed, not two game-hours later when its scaffolding comes down.
## A teaching counter that lags the tap teaches nothing.
const EVENT_KINDS: Dictionary = {
	&"build_archetype": {"event": &"building_placed_sim",
			"match_field": "archetype", "match_key": "archetype", "amount": ""},
	# `match_key` is `kind_id`, never `kind`: a row's `kind` is its OBJECTIVE
	# kind, and a component row needs a second name for the component itself.
	&"place_grid_component": {"event": &"grid_component_placed",
			"match_field": "kind", "match_key": "kind_id", "amount": ""},
	&"place_water_component": {"event": &"water_component_placed",
			"match_field": "kind", "match_key": "kind_id", "amount": ""},
	&"place_water_main": {"event": &"water_main_placed",
			"match_field": "", "match_key": "", "amount": "tiles"},
	&"stamp_road_tiles": {"event": &"road_build_started",
			"match_field": "", "match_key": "", "amount": "tiles"},
	&"upgrade_building": {"event": &"upgrade_started_sim",
			"match_field": "", "match_key": "", "amount": ""},
	# The same event, filtered by how far up the ladder the upgrade goes.
	# `min_field` is a NUMERIC floor rather than a string equality, because
	# "reach the tower tier" has to count an upgrade to the top rung and not an
	# upgrade to some particular rung: doc 02 §2.14 gives six of the twelve
	# archetypes a level 6 and the rest five, so a row asking for `to_level 6`
	# would be unanswerable by a police station and a row asking for equality
	# would refuse a player who went further. `>=` is the only reading that
	# survives an archetype-shaped ladder. Doc 09 §2.14's cost rule holds: this
	# is still one dictionary lookup and one comparison per event.
	&"upgrade_to_level": {"event": &"upgrade_started_sim",
			"match_field": "", "match_key": "", "amount": "",
			"min_field": "to_level", "min_key": "to_level"},
	&"repair_buildings": {"event": &"repair_started_sim",
			"match_field": "", "match_key": "", "amount": ""},
	&"resolve_incidents": {"event": &"incident_resolved",
			"match_field": "", "match_key": "", "amount": ""},
	&"buy_block": {"event": &"block_purchased",
			"match_field": "", "match_key": "", "amount": ""},
	&"develop_block": {"event": &"block_ready",
			"match_field": "", "match_key": "", "amount": ""},
	&"set_tax_rate": {"event": &"tax_rate_changed",
			"match_field": "", "match_key": "", "amount": ""},
	# Doc 06 §2.16's street tap. `match_field` is EMPTY, so the row counts a
	# collection of any kind — "collect 3 street opportunities", not "collect 3
	# crooks". The kind-specific reading is one authored key away (set
	# `match_field: "kind"` and give the row an `opportunity_kind`), and it is
	# deliberately not taken yet: a curriculum row that asks for a crook asks
	# the player to wait for a crime the police did not answer, and the level it
	# would sit on is the one that teaches building a police station.
	#
	# **No curriculum row uses it yet** — `data/goals.json` is untouched and
	# balance gate 21's fitted targets do not move. When one lands, level 4 is
	# where it fits: that level already teaches the police station, so "there
	# are still crimes it misses, and here is what you do about them" is the
	# sentence the objective would be finishing.
	&"collect_opportunities": {"event": &"opportunity_collected",
			"match_field": "", "match_key": "", "amount": ""},
}

## Kinds that READ STATE, and the key each one reads out of [reconcile]'s view.
## Compared as floats against the row's `target`; the target is inclusive.
##
## Every one of these is an O(1) scalar the sim already keeps. That is not a
## coincidence and it is the boundary of this table: a "power coverage ≥ 95 %"
## objective would be a roster walk per game-hour to answer, and doc 09 §2.14's
## cost rule says the reconcile reads scalars. When doc 04 publishes a city-wide
## availability scalar it can join; until then it may not.
const STATE_KINDS: Dictionary = {
	&"reach_population": "population",
	&"reach_happiness": "happiness",
	&"reach_stability": "stability",
	&"reach_treasury": "treasury",
}

## The endurance kind: `target` game-hours in a row without any of [BAD_EVENTS].
## Counts on the hour, resets to zero the moment one of them lands. Doc 09
## §2.14 names it `survive_week_no_abandonment`; the window is a row field so a
## curriculum level can ask for a game-day instead of a game-week.
const KIND_SURVIVE := &"survive_no_abandonment"

## What breaks the streak. Not a preference — these are the three events that
## mean the city lost something it was holding.
const BAD_EVENTS: Array[StringName] = [
	&"incident_abandoned", &"incident_failed", &"building_destroyed",
]

## `view()`'s answer while the curriculum is finished. Public so `ui/` can test
## against it rather than against a magic string.
const LEVEL_COMPLETE := -1

## Slack on the `current >= target` test. Counters are integers and land exactly;
## this is for the state kinds, whose readings are doubles and whose targets are
## authored decimals — `happiness >= 70.0` must not miss on 69.99999999999999.
const EPSILON := 1.0e-7

## Process-wide because the curriculum is authored data. Handed out read-only.
static var _levels: Array = []
static var _loaded := false

## Highest curriculum level whose objectives are ALL complete. Monotone.
var earned_level: int = 0
## Objective id -> integer progress. Event counters and the endurance streak
## live here; state kinds do not (they are re-read, see `_state_progress`).
var progress: Dictionary = {}
## Objective id -> true, sticky. A completed objective never un-completes, for
## the same reason doc 09 §2.11's level never falls: a disaster may not take
## back something the player did.
var done: Dictionary = {}

## The last state view [reconcile] was given. DERIVED — never serialized: a load
## re-reads it from the restored city before the next tick.
var _view: Dictionary = {}
## Objective id -> the reading its last `goal_progress` carried. DERIVED, and the
## reason the per-hour reconcile is not an event storm: a population objective
## whose reading has not moved says nothing.
var _emitted: Dictionary = {}
var _events: Array[Dictionary] = []


# ------------------------------------------------------------------ the data

## Doc 09 §8.3's curriculum, level 1 first. A file that will not parse degrades
## to an EMPTY curriculum rather than half of one — with no rows, every method
## here is inert and the city runs on doc 09 §2.11's population ladder alone,
## which is exactly the behaviour that shipped before this system existed.
static func levels() -> Array:
	if not _loaded:
		_loaded = true
		var rows: Variant = StarterCityLoader.read_json(DATA_PATH).get("levels", [])
		var parsed: Array = []
		if rows is Array:
			for raw: Variant in (rows as Array):
				if raw is Dictionary:
					parsed.append(GoalSystem._normalize_level(raw as Dictionary))
		parsed.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			return int(a["level"]) < int(b["level"]))
		_levels = parsed
	return _levels


## Test seam: forget the cached parse. Only `tests/` calls it — the game reads
## the file once and the file cannot change under a running city.
static func reset_cache() -> void:
	_levels = []
	_loaded = false


static func _normalize_level(row: Dictionary) -> Dictionary:
	var objectives: Array = []
	var raw: Variant = row.get("objectives", [])
	if raw is Array:
		for entry: Variant in (raw as Array):
			if not (entry is Dictionary):
				continue
			var obj: Dictionary = (entry as Dictionary).duplicate(true)
			obj["id"] = str(obj.get("id", ""))
			obj["kind"] = StringName(str(obj.get("kind", "")))
			obj["target"] = float(obj.get("target", 1.0))
			obj["text_key"] = str(obj.get("text_key", ""))
			if obj["id"] != "" and GoalSystem.is_known_kind(obj["kind"]):
				objectives.append(obj)
	return {
		"level": int(row.get("level", 0)),
		"title_key": str(row.get("title_key", "")),
		"intent_key": str(row.get("intent_key", "")),
		"teaches_key": str(row.get("teaches_key", "")),
		"objectives": objectives,
	}


static func is_known_kind(kind: StringName) -> bool:
	return EVENT_KINDS.has(kind) or STATE_KINDS.has(kind) or kind == KIND_SURVIVE


## The highest level the curriculum can carry the player to.
static func top_level() -> int:
	var rows := levels()
	return 0 if rows.is_empty() else int((rows[rows.size() - 1] as Dictionary)["level"])


static func level_row(level: int) -> Dictionary:
	for raw: Variant in levels():
		var row: Dictionary = raw
		if int(row["level"]) == level:
			return row
	return {}


# --------------------------------------------------------------- the machine

## The level the player is working on: one above the last one earned, or
## [LEVEL_COMPLETE] once the curriculum is finished.
func active_level() -> int:
	var next := earned_level + 1
	return next if not level_row(next).is_empty() else LEVEL_COMPLETE


## One sim event. Called synchronously from `SimEventBus.observer`, so it is
## deliberately cheap: one dictionary lookup, then at most the active level's
## handful of objectives.
func observe(event: Dictionary) -> void:
	var type := StringName(str(event.get("type", "")))
	if type == &"":
		return
	# Its own output is not its input. Without this the goal events appended to
	# the bus inside `emit()` would walk straight back in here.
	if String(type).begins_with("goal_") or type == &"city_level_objectives_met":
		return
	var level := active_level()
	if level == LEVEL_COMPLETE:
		return
	var streak_broken := BAD_EVENTS.has(type)
	var changed := false
	for raw: Variant in (level_row(level)["objectives"] as Array):
		var obj: Dictionary = raw
		var id := str(obj["id"])
		if bool(done.get(id, false)):
			continue
		var kind: StringName = obj["kind"]
		if kind == KIND_SURVIVE:
			if streak_broken and int(progress.get(id, 0)) != 0:
				progress[id] = 0
				changed = _note_progress(level, obj) or changed
			continue
		var rule: Variant = EVENT_KINDS.get(kind, null)
		if rule == null or (rule as Dictionary)["event"] != type:
			continue
		var spec: Dictionary = rule
		var match_field := str(spec["match_field"])
		if match_field != "" and str(event.get(match_field, "")) \
				!= str(obj.get(str(spec["match_key"]), "")):
			continue
		# Numeric floor, for the kinds that filter on how FAR an event went
		# rather than on what it named. An event missing the field cannot clear
		# a floor above zero, which is the safe direction.
		var min_field := str(spec.get("min_field", ""))
		if min_field != "" and float(event.get(min_field, 0.0)) \
				< float(obj.get(str(spec["min_key"]), 0.0)):
			continue
		var amount_field := str(spec["amount"])
		var amount := int(event.get(amount_field, 0)) if amount_field != "" else 1
		if amount <= 0:
			continue
		progress[id] = int(progress.get(id, 0)) + amount
		changed = _note_progress(level, obj) or changed
	if changed:
		_settle(level)


## One game-hour's state reading. `view` carries the scalars [STATE_KINDS] name;
## everything in it is O(1) off the live sim, which is what keeps this a
## per-hour reconcile rather than a per-tick scan.
func reconcile(view: Dictionary) -> void:
	_view = view.duplicate()
	var level := active_level()
	if level == LEVEL_COMPLETE:
		return
	var changed := false
	for raw: Variant in (level_row(level)["objectives"] as Array):
		var obj: Dictionary = raw
		var id := str(obj["id"])
		if bool(done.get(id, false)):
			continue
		var kind: StringName = obj["kind"]
		if kind == KIND_SURVIVE:
			progress[id] = int(progress.get(id, 0)) + 1
			changed = _note_progress(level, obj) or changed
		elif STATE_KINDS.has(kind):
			changed = _note_progress(level, obj) or changed
	if changed:
		_settle(level)


## Emits `goal_progress` for one objective and marks it done when it lands.
## Returns whether anything actually moved — a per-hour reconcile of a
## population objective that has not budged must not publish an event.
func _note_progress(level: int, obj: Dictionary) -> bool:
	var id := str(obj["id"])
	var target := float(obj["target"])
	var current := current_of(obj)
	var landed := current + EPSILON >= target
	if not landed and _emitted.has(id) and is_equal_approx(float(_emitted[id]), current):
		return false
	_emitted[id] = current
	_events.append({"type": &"goal_progress", "goal_id": id, "level": level,
			"current": current, "target": target})
	if landed:
		done[id] = true
		_events.append({"type": &"goal_completed", "goal_id": id, "level": level})
	return true


## Promotes as many levels as the current progress has earned. A cascade is
## normal on [bootstrap] and impossible in play, where one event can complete at
## most one level.
func _settle(from_level: int) -> void:
	var level := from_level
	while level != LEVEL_COMPLETE and _all_done(level):
		earned_level = level
		_events.append({"type": &"city_level_objectives_met", "level": level})
		level = active_level()
		# A newly active level may already be satisfied by state the city
		# already has (the migration case); re-read it before testing again.
		if level != LEVEL_COMPLETE:
			for raw: Variant in (level_row(level)["objectives"] as Array):
				var obj: Dictionary = raw
				if STATE_KINDS.has(obj["kind"]) and not bool(done.get(str(obj["id"]), false)):
					_note_progress(level, obj)


func _all_done(level: int) -> bool:
	var row := level_row(level)
	if row.is_empty():
		return false
	var objectives: Array = row["objectives"]
	if objectives.is_empty():
		return false
	for raw: Variant in objectives:
		if not bool(done.get(str((raw as Dictionary)["id"]), false)):
			return false
	return true


## An objective's progress in the units its target is quoted in.
func current_of(obj: Dictionary) -> float:
	var id := str(obj["id"])
	var target := float(obj["target"])
	if bool(done.get(id, false)):
		return target
	var kind: StringName = obj["kind"]
	if STATE_KINDS.has(kind):
		return float(_view.get(String(STATE_KINDS[kind]), 0.0))
	return float(int(progress.get(id, 0)))


func drain_events() -> Array[Dictionary]:
	var out := _events
	_events = [] as Array[Dictionary]
	return out


# ------------------------------------------------------- retroactive bootstrap

## Initialise a city that has been played WITHOUT this system — a save written
## before doc 09 §2.14 landed, restored into a build that has it.
##
## Doc 08 §2.8's migrator may not read `data/`, and it could not do this job
## anyway: the answer depends on the whole restored city, which the migrator
## never sees. So the migrator only marks the body, and `CitySim.restore_state`
## calls this once the city is standing.
##
## Two rules, and both of them are about not insulting the player:
##
##  1. **Every level at or below the city's own level is complete.** A player at
##     city level 4 is not asked to build their first house. This is TOTAL: it
##     does not matter whether the objectives were reachable, whether the verbs
##     existed, or what the counters would have said — the level was earned.
##  2. **The active level starts from what the city already HAS.** `counts`
##     carries the observable residue of the event kinds (houses standing,
##     transformers placed, blocks owned); a kind with no residue — incidents
##     resolved, repairs made — starts at zero, because a city cannot be asked
##     what it once did.
func bootstrap(city_level: int, counts: Dictionary, view: Dictionary) -> void:
	_view = view.duplicate()
	for raw_level: Variant in levels():
		var row: Dictionary = raw_level
		if int(row["level"]) > city_level:
			continue
		for raw: Variant in (row["objectives"] as Array):
			done[str((raw as Dictionary)["id"])] = true
		earned_level = maxi(earned_level, int(row["level"]))
	var level := active_level()
	if level == LEVEL_COMPLETE:
		return
	for raw: Variant in (level_row(level)["objectives"] as Array):
		var obj: Dictionary = raw
		var key := residue_key(obj)
		if key != "":
			progress[str(obj["id"])] = int(counts.get(key, 0))
		_note_progress(level, obj)
	_settle(level)


## Which key of [bootstrap]'s `counts` holds an objective's observable residue,
## or `""` when the city keeps no record of that verb. Static and pure so
## `CitySim` can build exactly the counts the curriculum asks for and no more.
static func residue_key(obj: Dictionary) -> String:
	match StringName(obj.get("kind", &"")):
		&"build_archetype":
			return "archetype:" + str(obj.get("archetype", ""))
		&"place_grid_component":
			return "grid:" + str(obj.get("kind_id", ""))
		&"place_water_component":
			return "water:" + str(obj.get("kind_id", ""))
		&"place_water_main":
			return "water_main_tiles"
		&"stamp_road_tiles":
			return "road_tiles"
		&"buy_block":
			return "blocks_owned"
		&"develop_block":
			return "blocks_ready"
		_:
			return ""


## Every residue key the curriculum can possibly ask for, so the boot-time count
## walk gathers each one exactly once. Sorted — a deterministic walk order.
static func residue_keys() -> Array[String]:
	var out: Array[String] = []
	for raw_level: Variant in levels():
		for raw: Variant in ((raw_level as Dictionary)["objectives"] as Array):
			var key := residue_key(raw as Dictionary)
			if key != "" and not out.has(key):
				out.append(key)
	out.sort()
	return out


# ------------------------------------------------------------------- readouts

## The whole curriculum state as plain data, for `ui/` and for the tests. No
## Node, no config, no copy: the view names string KEYS and the UI resolves them.
func view() -> Dictionary:
	var level := active_level()
	var out := {
		"earned_level": earned_level,
		"level": level,
		"complete": level == LEVEL_COMPLETE,
		"title_key": "", "intent_key": "", "teaches_key": "",
		"objectives": [], "done_count": 0, "total_count": 0,
		"next_level": earned_level + 2,
	}
	if level == LEVEL_COMPLETE:
		return out
	var row := level_row(level)
	out["title_key"] = row["title_key"]
	out["intent_key"] = row["intent_key"]
	out["teaches_key"] = row["teaches_key"]
	var rows: Array = []
	var done_count := 0
	for raw: Variant in (row["objectives"] as Array):
		var obj: Dictionary = raw
		var id := str(obj["id"])
		var complete := bool(done.get(id, false))
		if complete:
			done_count += 1
		rows.append({
			"id": id, "kind": String(obj["kind"]), "text_key": str(obj["text_key"]),
			"target": float(obj["target"]), "current": current_of(obj),
			"done": complete,
			"archetype": str(obj.get("archetype", "")),
			"kind_id": str(obj.get("kind_id", "")),
		})
	out["objectives"] = rows
	out["done_count"] = done_count
	out["total_count"] = rows.size()
	return out


## `"2/3"` for the HUD chip, or `""` once the curriculum is finished.
func chip_text() -> String:
	var level := active_level()
	if level == LEVEL_COMPLETE:
		return ""
	var row := level_row(level)
	var total: int = (row["objectives"] as Array).size()
	var count := 0
	for raw: Variant in (row["objectives"] as Array):
		if bool(done.get(str((raw as Dictionary)["id"]), false)):
			count += 1
	return "%d/%d" % [count, total]


# ---------------------------------------------------------------- persistence

## Doc 08 §2.8: this block rides the `city` section (`CitySim.capture_state`).
## `done` is written as a SORTED array rather than a dictionary because a save
## body is compared byte-for-byte by `state_hash()` — a set with a stable order
## is a set that hashes the same twice.
func serialize() -> Dictionary:
	var done_ids: Array = done.keys()
	done_ids.sort()
	var counters: Dictionary = {}
	var ids: Array = progress.keys()
	ids.sort()
	for id: Variant in ids:
		counters[str(id)] = int(progress[id])
	return {"version": 1, "earned_level": earned_level,
			"done": done_ids, "progress": counters}


func deserialize(data: Dictionary) -> void:
	earned_level = int(data.get("earned_level", 0))
	done = {}
	for id: Variant in data.get("done", []):
		done[str(id)] = true
	progress = {}
	var counters: Variant = data.get("progress", {})
	if counters is Dictionary:
		for id: Variant in (counters as Dictionary):
			progress[str(id)] = int((counters as Dictionary)[id])
	_view = {}
	_emitted = {}
	_events = [] as Array[Dictionary]
