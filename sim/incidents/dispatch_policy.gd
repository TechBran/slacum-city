class_name DispatchPolicy
extends RefCounted
## Doc 06 §2.12. Policies are evaluated by ONE function, called from the
## identical assignment loop in both the online and the offline path. There is
## no offline-only branch anywhere in dispatch — that is a hard invariant and
## `test_incidents_dispatch.gd` asserts the call sequence matches.

var values: Dictionary = {}
## Instrumentation for the "identical in both paths" invariant test: every
## allows() call appends {unit_id, incident_id, result}.
var trace_enabled: bool = false
var trace: Array = []


func _init(defaults: Dictionary = {}) -> void:
	values = defaults.duplicate(true)


func get_value(key: String, fallback: Variant = null) -> Variant:
	return values.get(key, fallback)


func get_bool(key: String, fallback: bool = false) -> bool:
	return bool(values.get(key, fallback))


func get_int(key: String, fallback: int = 0) -> int:
	return int(values.get(key, fallback))


func set_value(key: String, value: Variant) -> bool:
	if not values.has(key):
		return false
	values[key] = value
	return true


## The single gate. `fleet` supplies the reserve count; `world` prices the
## repair cap (doc 03 — the cap is a dollar limit, not a price table).
func allows(unit: Vehicle, inc: Incident, priority: float, fleet: FleetSystem,
		world: IncidentWorld, expected_damage_fraction: float) -> bool:
	var result := _allows_inner(unit, inc, priority, fleet, world, expected_damage_fraction)
	if trace_enabled:
		trace.append({"unit_id": unit.id, "incident_id": inc.id, "result": result})
	return result


func _allows_inner(unit: Vehicle, inc: Incident, priority: float, fleet: FleetSystem,
		world: IncidentWorld, expected_damage_fraction: float) -> bool:
	if inc.manual_requested:
		return true  # a player command bypasses everything
	if not get_bool("auto_dispatch_" + unit.department, true):
		return false
	if unit.department == "police" \
			and priority < float(get_int("auto_dispatch_police_min_priority", 0)):
		return false
	var cap := get_int("auto_repair_cost_cap", 0)
	if cap > 0 and inc.tier() < 4:
		if world.repair_cost(inc.target_ref, expected_damage_fraction) > cap:
			return false
	if breaks_reserve(unit, fleet) and inc.tier() < get_int("reserve_break_tier", 4):
		if _department_already_responding(unit.department, inc, fleet):
			return false
	return true


## The HARD case: below `reserve_break_tier` a reserve-breaking unit is not
## considered at all. The SOFT case (at or above it) is priced by
## RESERVE_PENALTY inside the assignment cost function.
func breaks_reserve(unit: Vehicle, fleet: FleetSystem) -> bool:
	var reserve := get_int(unit.department + "_reserve_units", 0)
	if reserve <= 0:
		return false
	return fleet.idle_count_at_station(unit.department, unit.home_station_id) <= reserve


## DEVIATION FROM THE LITERAL §2.12 RULE, and a deliberate one.
##
## Read literally, `breaks_reserve` also blocks the FIRST engine whenever a
## station houses exactly `fire_reserve_units` of them — which is every L1 fire
## station, i.e. the whole starter city. A city with one engine could then not
## answer a fire below tier 4, which is not a reserve, it is a broken response.
## The reserve therefore binds REINFORCEMENTS only: the first unit of a
## department on an incident is never refused. Doc 06's own test 15 is
## unchanged by this (2 engines, reserve 1: a tier-2 fire still takes exactly
## one, a tier-4 fire still takes both).
func _department_already_responding(department: String, inc: Incident,
		fleet: FleetSystem) -> bool:
	for unit_id in inc.assigned:
		var other: Vehicle = fleet.unit(int(unit_id))
		if other != null and other.department == department:
			return true
	return false


func serialize() -> Dictionary:
	return values.duplicate(true)


func deserialize(data: Dictionary) -> void:
	for key in data:
		if values.has(key):
			values[key] = data[key]
