class_name DirectorTables
extends RefCounted
## Validated view of `data/director.json` (doc 07 §8.2) plus the event catalog.
##
## The four difficulty knobs are NOT here (report 98 C-17): they are the
## `pressure` section of doc 03's `data/difficulty.json`, read through
## `Difficulty.get("pressure", key)`. Until that file lands, `_difficulty_fallback`
## in the data file mirrors doc 07 §8.3 read-only, and
## `DisasterDirector.set_pressure_knobs()` replaces it the moment doc 03 ships.

const SCHEMA_VERSION := 1
const CLASS_MINOR := "minor"
const CLASS_MAJOR := "major"

const PRESSURE_KEYS: Array[String] = [
	"tp_rate_mult", "cooldown_mult", "severity_mult", "warning_lead_mult",
]

var tp: Dictionary = {}
## doc 92 F-1's size-independent pressure floor (see the data file's own note).
var floor_config: Dictionary = {}
var preparedness: Dictionary = {}
var severity: Dictionary = {}
var scheduling: Dictionary = {}
var fairness: Dictionary = {}
var storm: Dictionary = {}
var events: Array = []  # catalog rows, in file order (deterministic)
var errors: PackedStringArray = []

var _by_id: Dictionary = {}
var _difficulty_fallback: Dictionary = {}


static func load_from_file(path: String) -> DirectorTables:
	var tables := DirectorTables.new()
	if not FileAccess.file_exists(path):
		tables.errors.append("director data missing: " + path)
		return tables
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		tables.errors.append("director data is not a JSON object: " + path)
		return tables
	tables.load_from(parsed)
	return tables


func load_from(data: Dictionary) -> bool:
	errors.clear()
	if int(data.get("schema_version", -1)) != SCHEMA_VERSION:
		errors.append("director.json schema_version must be %d" % SCHEMA_VERSION)
		return false
	tp = data.get("tp", {})
	floor_config = data.get("floor", {})
	preparedness = data.get("preparedness", {})
	severity = data.get("severity", {})
	scheduling = data.get("scheduling", {})
	fairness = data.get("fairness", {})
	storm = data.get("storm", {})
	events = data.get("events", [])
	_difficulty_fallback = data.get("_difficulty_fallback", {})
	_by_id.clear()
	for event in events:
		var id := String(event.get("id", ""))
		if id == "":
			errors.append("catalog row without an id")
			continue
		if _by_id.has(id):
			errors.append("duplicate catalog id " + id)
		_by_id[id] = event
		if not [CLASS_MINOR, CLASS_MAJOR].has(String(event.get("class", ""))):
			errors.append("%s: class must be minor|major" % id)
		var tier := int(event.get("hazard_tier", 0))
		if tier < 1 or tier > 3:
			errors.append("%s: hazard_tier must be 1..3" % id)
		if bool(event.get("forecastable", false)) and int(event.get("warn_min", 0)) <= 0:
			errors.append("%s: forecastable events need warn_min > 0 (F7)" % id)
	# C-17: this file may not carry difficulty knobs or a repair price.
	if data.has("difficulty"):
		errors.append("director.json must not carry a difficulty block (C-17)")
	if data.has("repair_cost_mult"):
		errors.append("director.json must not carry repair_cost_mult (C-17)")
	return errors.is_empty()


func is_valid() -> bool:
	return errors.is_empty()


func event_by_id(id: String) -> Dictionary:
	return _by_id.get(id, {})


func difficulty_fallback(preset: String) -> Dictionary:
	var row: Dictionary = _difficulty_fallback.get(preset, _difficulty_fallback.get("standard", {}))
	var out := {}
	for key in PRESSURE_KEYS:
		out[key] = float(row.get(key, 1.0))
	out["soft_suppression"] = bool(row.get("soft_suppression", true))
	return out


## §2.6.2 city-size ladder. Distinct from `hazard_tier`, which is the
## consequence class doc 08's offline rule gates on (C-55).
func city_tier(population: int) -> int:
	var thresholds: Array = tp.get("tier_pop_thresholds", [2000, 10000, 40000, 120000])
	var tier := 0
	for threshold in thresholds:
		if population >= int(threshold):
			tier += 1
	return tier


func tp_base_per_day(tier: int) -> float:
	var table: Array = tp.get("base_per_day_by_tier", [0, 6, 12, 20, 30])
	return maxf(float(table[clampi(tier, 0, table.size() - 1)]), floor_tp_per_day())


## doc 92 F-1: the size-independent minimum accrual, in threat points per
## game-day. 0 when the floor is disabled, so the tier ladder is then the only
## authority — and even enabled, `max()` means it is invisible above tier 0.
func floor_tp_per_day() -> float:
	if not floor_enabled():
		return 0.0
	return float(floor_config.get("tp_per_day", 0.0))


func floor_enabled() -> bool:
	return bool(floor_config.get("enabled", false))


## The catalog rows the floor is allowed to unlock for a city below an event's
## own `min_city_tier`: minor class, hazard tier 1, cheap. A small city gets
## weather and a cooked transformer; it does not get a major structure fire.
func floor_allows(event: Dictionary) -> bool:
	if not floor_enabled():
		return false
	var classes: Array = floor_config.get("classes", [CLASS_MINOR])
	if not classes.has(String(event.get("class", ""))):
		return false
	if int(event.get("hazard_tier", 3)) > int(floor_config.get("max_hazard_tier", 1)):
		return false
	return float(event.get("tp_cost", 0)) <= float(floor_config.get("max_tp_cost", 0))


## The floor's own grace: doc 07 F1 holds the Director off a city that is both
## young AND small, which a founding city never stops being. The floor keeps the
## age half of that gate and drops the population half.
func floor_grace_days() -> int:
	return int(floor_config.get("grace_days", 3))


func lightning() -> Dictionary:
	return storm.get("lightning", {})


func storm_phases() -> Dictionary:
	return storm.get("phases", {})
