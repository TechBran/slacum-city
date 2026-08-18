class_name ProgressionSystem
extends RefCounted
## City level and milestones (doc 09 §2.11, gaps G-1/G-4). Monotone by
## design: a disaster must never re-lock what the player has earned.

const CITY_LEVEL_POP: Array[int] = [0, 250, 1000, 4000, 12000, 30000]

var city_level: int = 0
var milestones: Array = []  # one-shot ids, in the order earned


static func level_reached(city_population: int) -> int:
	var reached := 0
	for i in CITY_LEVEL_POP.size():
		if city_population >= CITY_LEVEL_POP[i]:
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
	if city_level + 1 >= CITY_LEVEL_POP.size():
		return -1
	return CITY_LEVEL_POP[city_level + 1]


func serialize() -> Dictionary:
	return {"section_version": 1, "city_level": city_level,
			"city_level_max": city_level, "milestones": milestones.duplicate()}


func deserialize(data: Dictionary) -> void:
	city_level = int(data.get("city_level_max", data.get("city_level", 0)))
	milestones = data.get("milestones", [])
