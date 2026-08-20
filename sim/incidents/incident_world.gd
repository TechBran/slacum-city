class_name IncidentWorld
extends RefCounted
## The single cross-system seam for doc 06 (§5). Every read this system makes
## of docs 02/03/04/05/07/09/10 and every write it makes back to them passes
## through one of these methods — so the incident engine is testable with a
## stub, and the CitySim adapter is the only place that knows about PowerGrid,
## Building, DistrictRegistry or Treasury.
##
## Every method here has a benign default, so a subclass implements only what
## its city actually has. That is what lets doc 06 land before docs 05/07/10.
##
## Positions are GLOBAL TILES (constitution §6, 1 tile = 8 m). Metres are only
## used where the doc's formulas are in metres (fire spread radii).

const METRES_PER_TILE := 8.0


# ---------------------------------------------------------------- doc 01 time

## Doc 08 fairness rule 4 (C-47): false for every offline hour. The two
## irreversible verbs check this BEFORE doing anything.
func destroy_allowed() -> bool:
	return true


## True while the offline catch-up driver is running (doc 08). Generation-rate
## clamps read it; the escalation and resolution math never do.
func is_offline() -> bool:
	return false


# ----------------------------------------------------------- doc 02 buildings

## Ids of every building the incident engine may touch, ASCENDING.
func building_ids() -> Array:
	return []


## Doc 02 §2.9's service-coverage scalars (report 98 C-51 — doc 02 owns the
## formula, doc 06 only reads the number). Both ∈ [0,1].
##
## The neutral default is **0.0**, not 0.5: a world with no station roster has no
## coverage, and 0.5 is a value the crime generator would treat as half a police
## force that does not exist. A test world that wants a coverage figure states it
## on the district row, which is where the generator reads it from.
func coverage_police(_tile: Vector2i) -> float:
	return 0.0


func coverage_fire(_tile: Vector2i) -> float:
	return 0.0


## {archetype, level, condition, occupants, powered, state, tile,
##  fire_load, fire_ignition_per_hour, crime_weight, district_id}
func building(_id: String) -> Dictionary:
	return {}


## Ids of buildings whose centre lies within `radius_m` of `tile`, ASCENDING,
## excluding `exclude_id`.
func buildings_within_m(_tile: Vector2i, _radius_m: float, _exclude_id: String = "") -> Array:
	return []


## The whole roster as the structure-fire generator wants it, ASCENDING by id.
## That generator runs on every integrator sub-step and reads exactly six
## fields, so a world with a cheaper way to produce those six overrides this;
## the default composes the full `building()` rows and is always correct.
## Required keys: id · state · condition · fire_ignition_per_hour · powered ·
## district_id.
func fire_candidate_rows() -> Array:
	var out: Array = []
	for id in building_ids():
		var row := building(String(id))
		if not row.is_empty():
			out.append(row)
	return out


## The SAME buildings in the SAME order as `fire_candidate_rows()`, as six
## parallel columns instead of six-key dictionaries:
##
##     {id: PackedStringArray, state: Array, condition: PackedFloat64Array,
##      fire_ignition_per_hour: PackedFloat64Array, powered: PackedByteArray,
##      district_id: PackedStringArray}
##
## This is what the structure-fire generator actually reads, and it reads the
## whole roster on every integrator sub-step: at 1,500 buildings the row form
## spends most of its time in Dictionary lookups for six numbers that a column
## hands over by index. A world with a cheaper way to fill the columns overrides
## this; the default derives them from `fire_candidate_rows()` and is therefore
## always correct for a world that only implements `building()`.
func fire_candidate_columns() -> Dictionary:
	var rows := fire_candidate_rows()
	var count := rows.size()
	var ids := PackedStringArray()
	var states: Array = []
	var conditions := PackedFloat64Array()
	var ignitions := PackedFloat64Array()
	var powered := PackedByteArray()
	var districts := PackedStringArray()
	ids.resize(count)
	states.resize(count)
	conditions.resize(count)
	ignitions.resize(count)
	powered.resize(count)
	districts.resize(count)
	for i in count:
		var row: Dictionary = rows[i]
		ids[i] = String(row.get("id", ""))
		states[i] = row.get("state", "active")
		conditions[i] = float(row.get("condition", 1.0))
		ignitions[i] = float(row.get("fire_ignition_per_hour", 0.0))
		powered[i] = 1 if bool(row.get("powered", true)) else 0
		districts[i] = String(row.get("district_id", ""))
	return {
		"id": ids, "state": states, "condition": conditions,
		"fire_ignition_per_hour": ignitions, "powered": powered,
		"district_id": districts,
	}


## Doc 02 §2.6: 1 + 1.5·(1 − condition)^1.5.
func fire_condition_mult(id: String) -> float:
	return fire_condition_mult_of(building(id))


## Doc 02 §2.12 per-state ignition multiplier (0 ⇒ ineligible candidate).
func state_fire_mult(id: String) -> float:
	return state_fire_mult_of(building(id))


## Row-taking twins of the two above. `building(id)` materialises a fresh row
## dictionary on every call, and the fire generator needs all three numbers for
## the same building on the same sub-step — so it fetches the row ONCE and calls
## these. Same arithmetic on the same row: the id-taking forms are these.
static func fire_condition_mult_of(row: Dictionary) -> float:
	if row.is_empty():
		return 1.0
	return fire_condition_mult_value(float(row.get("condition", 1.0)))


static func state_fire_mult_of(row: Dictionary) -> float:
	if row.is_empty():
		return 0.0
	return state_fire_mult_value(row.get("state", "active"))


## Value-taking forms, for the columnar seam above — the row-taking twins are
## these two plus their empty-row guards, so the two shapes cannot drift.
static func fire_condition_mult_value(condition: float) -> float:
	return 1.0 + 1.5 * pow(1.0 - clampf(condition, 0.0, 1.0), 1.5)


## `state` is compared, not converted: doc 02 writes it as a StringName and a
## String world writes it as a String, and Godot compares the two by content —
## so neither caller pays a StringName→String allocation per building per
## sub-step. Cases are mutually exclusive; the order is the old `match`'s.
static func state_fire_mult_value(state: Variant) -> float:
	if state == &"under_construction":
		return 1.4
	if state == &"damaged" or state == &"repairing":
		return 1.8
	if state == &"active":
		return 1.0
	return 0.0


func apply_building_damage(_id: String, _fraction: float) -> void:
	pass


## Raise a condition to at least `condition` (the roof-damage floor).
func set_building_condition_floor(_id: String, _condition: float) -> void:
	pass


## Lower a condition to at most `condition`. Doc 08 fairness rule 4's offline
## clamp: the building is wrecked but still standing, and the incident stays
## open (C-47).
func clamp_building_condition_max(_id: String, _condition: float) -> void:
	pass


func ignite_building(_id: String) -> bool:
	return false


func suppress_building_fire(_id: String, _residual_damage_fraction: float) -> void:
	pass


func destroy_building(_id: String, _cause: String) -> void:
	pass


# ------------------------------------------------------- doc 09 districts/pop

func district_ids() -> Array:
	return []


## {population, stability ∈ [0,1], police_coverage ∈ [0,1], outage_frac ∈ [0,1]}
func district(_id: String) -> Dictionary:
	return {}


func district_of_tile(_tile: Vector2i) -> String:
	return ""


func apply_district_stability(_id: String, _delta: float) -> void:
	pass


func apply_city_confidence(_delta: float) -> void:
	pass


func set_district_flag(_id: String, _flag: String, _value: float, _duration_h: float) -> void:
	pass


func apply_population_loss(_building_id: String, _fraction: float) -> void:
	pass


# ----------------------------------------------------------------- doc 04 power

## Per-node: {id, tile, load_ratio, condition, temp_c, redundancy, kind,
##            feeder, customers_downstream, critical_downstream}
func power_transformers() -> Array:
	return []


func power_component(_id: String) -> Dictionary:
	return {}


## The transformer roster as the failure generator SCANS it: {id, load_ratio,
## condition, temp_c} and nothing else. That scan runs on every integrator
## sub-step and reads exactly those three numbers; the full `power_component()`
## row — kind, tile, the downstream roll-up — is materialised only on the rare
## sub-step that actually spawns. A world with no cheaper answer hands back the
## full rows, which already contain them.
func power_transformer_rates() -> Array:
	return power_transformers()


func power_customers_downstream(_id: String) -> int:
	return 0


func power_feeder_load_shed(_id: String, _fraction: float) -> void:
	pass


func power_feeder_offline(_id: String) -> void:
	pass


## Terminal: the component is gone. Doc 06 supplies damage_fraction 1.0;
## doc 03 prices the replacement (C-16).
func power_feeder_destroy(_id: String) -> void:
	pass


## The offline counterpart of the destroy clamp, for power components.
func power_clamp_condition_max(_id: String, _condition: float) -> void:
	pass


## The repair verb the whole tutorial arc hangs on. The adapter decides between
## PowerGrid.repair_component() (a FAILED component) and force_close() (a
## tripped/locked-out one) — doc 06 only says "this is fixed now".
func power_restore_component(_id: String) -> void:
	pass


## Scripted failure (doc 07's Director / doc 12's onboarding). Returns true if
## the component was actually taken out.
func power_fail_component(_id: String, _cause: String) -> bool:
	return false


## C-53 storm candidates: {id, tile, exposure_class, condition, underground}
func power_exposed_components() -> Array:
	return []


# ----------------------------------------------------------------- doc 05 water

## ∈ [0, 1.2]. 1.0 (nominal) until doc 05 lands — fire response then degrades
## with pressure rather than being impossible (§2.8).
func hydrant_pressure_ratio(_tile: Vector2i) -> float:
	return 1.0


## Per-segment: {id, tile, length_km, condition, pressure_ratio, utilization,
##               freeze_stress, zone}
func water_mains() -> Array:
	return []


func water_set_segment_broken(_id: String, _severity: float) -> void:
	pass


func water_zone_pressure_delta(_zone: String, _delta: float) -> void:
	pass


func water_freeze_enabled() -> bool:
	return false


# --------------------------------------------------------------- doc 07 weather

## The ONLY way a weather number reaches doc 06 (RR-4 / RR-15). Six channels:
## incident_crime_mult, fire_ignition_mult, incident_utility_mult,
## incident_traffic_mult, fire_escalation_mult, fire_spread_mult.
## Passed through UNCLAMPED — re-clamping a doc 07 value would be doc 06
## retuning doc 07 by the back door (C-57).
func weather_effect(_channel: String) -> float:
	return 1.0


func wind_kph() -> float:
	return 0.0


## Radians in the XZ plane, 0 = +X, the direction the wind blows TOWARD.
func wind_dir_rad() -> float:
	return 0.0


func flood_saturation() -> float:
	return 0.0


func storm_flag() -> bool:
	return false


## {active, tile, radius_tiles}
func storm_cell() -> Dictionary:
	return {"active": false}


## Game-hours until the next weather-segment boundary (§2.1 breakpoint h).
## INF ⇒ weather never changes, so no breakpoint is needed.
func next_weather_boundary_h() -> float:
	return INF


# ---------------------------------------------------------------- doc 10 roads

## Intersections for the traffic_accident generator:
## {id, tile, congestion_index, signalised, signal_powered, condition_hazard_mult}
func road_intersections() -> Array:
	return []


func road_set_edge_speed_mult(_tile: Vector2i, _mult: float) -> void:
	pass


func road_close_edge(_tile: Vector2i, _duration_h: float) -> void:
	pass


# -------------------------------------------------------------- doc 03 economy

## Doc 06 supplies damage fractions and consumes prices; it authors neither
## (C-07 / C-16). Zero-cost defaults keep the engine runnable before doc 03
## exposes the vehicle ladder.
func repair_cost(_target_ref: Dictionary, _damage_fraction: float) -> int:
	return 0


func vehicle_dispatch_cost(_vehicle_type: String) -> int:
	return 0


func credit(_amount: int, _reason: String) -> void:
	pass


func debit(_amount: int, _reason: String) -> bool:
	return true


## data/difficulty.json `escalation` row, owned/loaded by doc 03 (C-17).
func difficulty_escalation_mult() -> float:
	return 1.0


func difficulty_generation_mult() -> float:
	return 1.0


# ------------------------------------------------------- doc 02 construction

## Crew preemption (G-2): the job a crew is bound to, or 0.
func crew_job_id(_crew_id: String) -> int:
	return 0


## Release the crew from its doc 02 job WITHOUT losing progress.
func release_crew_from_job(_job_id: int, _crew_id: String) -> void:
	pass
