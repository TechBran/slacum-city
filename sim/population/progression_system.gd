class_name ProgressionSystem
extends RefCounted
## City level and milestones (doc 09 §2.11, gaps G-1/G-4). Monotone by
## design: a disaster must never re-lock what the player has earned.
##
## The ladder is DATA (doc 09 §8.2's `data/progression.json`, written by doc 92
## §19). It used to be the `const` below and nothing else, which made it the one
## balance number in the game that could not be retuned without a code edit —
## and audit 91 D-7 is what that cost: a 12-game-day city that never left level 0
## and refused 376 upgrades with `E_CITY_LEVEL`.

## Doc 09 §8.2's file. Read once per process and cached: it is authored data,
## it does not change while the game runs, and `level_reached` is static because
## doc 12's build sheet asks the ladder a question without holding a city.
const DATA_PATH := "res://data/progression.json"

## Missing-file degrade, NOT a mirror: if `data/progression.json` cannot be read
## the game still has a ladder rather than none. Keep it equal to the file's own
## rows — `tests/test_balance_gates.gd::test_gate_20_*` asserts the two agree, so
## a drift is a failure and not a surprise.
const CITY_LEVEL_POP_FALLBACK: Array[int] = [0, 200, 700, 1600, 3600, 8000]

## Process-wide, because the ladder is authored data that cannot change while the
## game runs. Handed out read-only so a caller cannot edit the shared copy.
static var _thresholds: Array[int] = []

var city_level: int = 0
var milestones: Array = []  # one-shot ids, in the order earned


## Doc 09 §2.11's ladder, ascending, index = city level. A file with fewer than
## two rows is not a ladder, so it degrades to the compiled-in rows whole rather
## than half-applying.
static func city_level_pop() -> Array[int]:
	if _thresholds.is_empty():
		var rows: Array = StarterCityLoader.read_json(DATA_PATH).get(
				"city_level_population_thresholds", [])
		var parsed: Array[int] = []
		for row in rows:
			parsed.append(int(row))
		_thresholds = parsed if parsed.size() >= 2 else CITY_LEVEL_POP_FALLBACK.duplicate()
		_thresholds.make_read_only()
	return _thresholds


static func level_reached(city_population: int) -> int:
	var ladder := city_level_pop()
	var reached := 0
	for i in ladder.size():
		if city_population >= ladder[i]:
			reached = i
	return reached


## Returns events to emit: [{type, from, to}] for a level change plus any
## milestone events. Level never decreases.
func update(city_population: int) -> Array:
	var events: Array = []
	var reached := level_reached(city_population)
	if reached > city_level:
		events.append({"type": &"city_level_changed", "from": city_level, "to": reached})
		for level in range(city_level + 1, reached + 1):
			events.append_array(grant("city_level_%d" % level))
		city_level = reached
	if city_population >= 1000:
		events.append_array(grant("population_1k"))
	if city_population >= 10000:
		events.append_array(grant("population_10k"))
	return events


## One-shot milestone grant; returns the event array (empty if already held).
func grant(milestone_id: String) -> Array:
	if milestones.has(milestone_id):
		return []
	milestones.append(milestone_id)
	return [{"type": &"progression_milestone", "id": milestone_id}]


func has_milestone(milestone_id: String) -> bool:
	return milestones.has(milestone_id)


## Doc 12's "population 810 / 1,000 to level 3" readout.
func next_level_threshold() -> int:
	var ladder := city_level_pop()
	if city_level + 1 >= ladder.size():
		return -1
	return ladder[city_level + 1]


func serialize() -> Dictionary:
	return {"section_version": 1, "city_level": city_level,
			"city_level_max": city_level, "milestones": milestones.duplicate()}


func deserialize(data: Dictionary) -> void:
	city_level = int(data.get("city_level_max", data.get("city_level", 0)))
	milestones = data.get("milestones", [])
