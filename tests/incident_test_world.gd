class_name IncidentTestWorld
extends IncidentWorld
## Headless stub of doc 06's cross-system seam. Every doc 02/03/04/05/07/09/10
## read is a plain Dictionary the test authors directly, and every write is
## recorded so a test can assert it happened exactly once.
##
## Not named test_*.gd, so the runner does not try to execute it as a suite.

var buildings: Dictionary = {}  # id -> row
var districts: Dictionary = {}  # id -> row
var components: Dictionary = {}  # id -> row
var mains: Array = []
var intersections: Array = []
var exposed: Array = []

var allow_destroy: bool = true
var offline: bool = false
var hydrant_ratio: float = 1.0
var weather_channels: Dictionary = {}
var wind: float = 0.0
var wind_dir: float = 0.0
var flood: float = 0.0
var storm: bool = false
var storm_cell_row: Dictionary = {"active": false}
var weather_boundary_h: float = INF
var freeze_enabled: bool = false
var escalation_mult: float = 1.0
var generation_mult: float = 1.0
var repair_cost_value: int = 0
var dispatch_cost_value: int = 0

# --- recorded writes -------------------------------------------------------
var destroyed: Array = []
var damaged: Array = []
var condition_floors: Array = []
var ignited: Array = []
var suppressed: Array = []
var restored: Array = []
var failed_components: Array = []
var shed_calls: Array = []
var offline_calls: Array = []
var feeder_destroyed: Array = []
var stability_deltas: Array = []
var confidence_deltas: Array = []
var district_flags: Array = []
var population_losses: Array = []
var zone_pressure: Array = []
var edge_speed: Array = []
var edge_closed: Array = []
var credits: Array = []
var debits: Array = []
var channel_reads: Array = []
var released_jobs: Array = []


func add_building(id: String, archetype: String, level: int, tile: Vector2i,
		district_id: String = "D1", extra: Dictionary = {}) -> Dictionary:
	var row := {
		"id": id, "archetype": archetype, "level": level, "tile": tile,
		"condition": 1.0, "occupants": 0.0, "powered": true, "state": "active",
		"fire_load": 20.0, "fire_ignition_per_hour": 0.0, "crime_weight": 1.0,
		"district_id": district_id,
	}
	for key in extra:
		row[key] = extra[key]
	buildings[id] = row
	return row


func add_district(id: String, population: float, stability: float,
		police_coverage: float = 0.5, outage_frac: float = 0.0) -> void:
	districts[id] = {"id": id, "population": population, "stability": stability,
			"police_coverage": police_coverage, "outage_frac": outage_frac}


func add_component(id: String, tile: Vector2i, extra: Dictionary = {}) -> Dictionary:
	var row := {"id": id, "kind": "transformer", "tile": tile, "load_ratio": 0.85,
			"condition": 1.0, "temp_c": 25.0, "redundancy": false,
			"customers_downstream": 0, "critical_downstream": false, "state": "OK"}
	for key in extra:
		row[key] = extra[key]
	components[id] = row
	return row


# --- doc 01 ----------------------------------------------------------------

func destroy_allowed() -> bool:
	return allow_destroy


func is_offline() -> bool:
	return offline


# --- doc 02 ----------------------------------------------------------------

func building_ids() -> Array:
	var keys := buildings.keys()
	keys.sort()
	return keys


func building(id: String) -> Dictionary:
	return buildings.get(id, {})


func buildings_within_m(tile: Vector2i, radius_m: float, exclude_id: String = "") -> Array:
	var origin := Vector2(float(tile.x) * 8.0 + 4.0, float(tile.y) * 8.0 + 4.0)
	var out: Array = []
	for id in building_ids():
		if String(id) == exclude_id:
			continue
		var other: Vector2i = buildings[id]["tile"]
		var centre := Vector2(float(other.x) * 8.0 + 4.0, float(other.y) * 8.0 + 4.0)
		if origin.distance_to(centre) <= radius_m:
			out.append(String(id))
	return out


## `fraction` is DAMAGE: positive lowers the condition.
func apply_building_damage(id: String, fraction: float) -> void:
	damaged.append({"id": id, "fraction": fraction})
	if buildings.has(id):
		buildings[id]["condition"] = clampf(float(buildings[id]["condition"]) - fraction, 0.0, 1.0)


func set_building_condition_floor(id: String, condition: float) -> void:
	condition_floors.append({"id": id, "condition": condition})
	if buildings.has(id):
		buildings[id]["condition"] = maxf(float(buildings[id]["condition"]), condition)


func clamp_building_condition_max(id: String, condition: float) -> void:
	condition_floors.append({"id": id, "condition": condition, "clamp": true})
	if buildings.has(id):
		buildings[id]["condition"] = minf(float(buildings[id]["condition"]), condition)


func power_clamp_condition_max(id: String, condition: float) -> void:
	if components.has(id):
		components[id]["condition"] = minf(float(components[id]["condition"]), condition)


func ignite_building(id: String) -> bool:
	ignited.append(id)
	if buildings.has(id):
		buildings[id]["state"] = "on_fire"
	return true


func suppress_building_fire(id: String, residual_damage_fraction: float) -> void:
	suppressed.append({"id": id, "damage": residual_damage_fraction})
	if buildings.has(id):
		buildings[id]["state"] = "damaged"
		buildings[id]["condition"] = clampf(1.0 - residual_damage_fraction, 0.0, 1.0)


func destroy_building(id: String, cause: String) -> void:
	destroyed.append({"id": id, "cause": cause})
	if buildings.has(id):
		buildings[id]["state"] = "destroyed"


# --- doc 09 ----------------------------------------------------------------

func district_ids() -> Array:
	var keys := districts.keys()
	keys.sort()
	return keys


func district(id: String) -> Dictionary:
	return districts.get(id, {})


func district_of_tile(_tile: Vector2i) -> String:
	var ids := district_ids()
	return String(ids[0]) if not ids.is_empty() else ""


func apply_district_stability(id: String, delta: float) -> void:
	stability_deltas.append({"id": id, "delta": delta})
	if districts.has(id):
		districts[id]["stability"] = clampf(float(districts[id]["stability"]) + delta, 0.0, 1.0)


func apply_city_confidence(delta: float) -> void:
	confidence_deltas.append(delta)


func set_district_flag(id: String, flag: String, value: float, duration_h: float) -> void:
	district_flags.append({"id": id, "flag": flag, "value": value, "duration_h": duration_h})


func apply_population_loss(building_id: String, fraction: float) -> void:
	population_losses.append({"id": building_id, "fraction": fraction})


# --- doc 04 ----------------------------------------------------------------

func power_transformers() -> Array:
	var out: Array = []
	var keys := components.keys()
	keys.sort()
	for id in keys:
		if String(components[id].get("kind", "transformer")) == "transformer":
			out.append(components[id])
	return out


func power_component(id: String) -> Dictionary:
	return components.get(id, {})


func power_customers_downstream(id: String) -> int:
	return int(components.get(id, {}).get("customers_downstream", 0))


func power_feeder_load_shed(id: String, fraction: float) -> void:
	shed_calls.append({"id": id, "fraction": fraction})


func power_feeder_offline(id: String) -> void:
	offline_calls.append(id)
	if components.has(id):
		components[id]["state"] = "OPEN"


func power_feeder_destroy(id: String) -> void:
	feeder_destroyed.append(id)
	if components.has(id):
		components[id]["state"] = "DESTROYED"


func power_restore_component(id: String) -> void:
	restored.append(id)
	if components.has(id):
		components[id]["state"] = "OK"


func power_fail_component(id: String, cause: String) -> bool:
	if not components.has(id):
		return false
	failed_components.append({"id": id, "cause": cause})
	components[id]["state"] = "FAILED"
	return true


func power_exposed_components() -> Array:
	return exposed


# --- doc 05 ----------------------------------------------------------------

func hydrant_pressure_ratio(_tile: Vector2i) -> float:
	return hydrant_ratio


func water_mains() -> Array:
	return mains


func water_set_segment_broken(id: String, severity: float,
		incident_id: String = "") -> void:
	zone_pressure.append({"segment": id, "severity": severity,
			"incident_id": incident_id})


func water_zone_pressure_delta(zone: String, delta: float,
		segment_id: String = "") -> void:
	zone_pressure.append({"zone": zone, "delta": delta, "segment": segment_id})


func water_freeze_enabled() -> bool:
	return freeze_enabled


# --- doc 07 ----------------------------------------------------------------

func weather_effect(channel: String) -> float:
	channel_reads.append(channel)
	return float(weather_channels.get(channel, 1.0))


func wind_kph() -> float:
	return wind


func wind_dir_rad() -> float:
	return wind_dir


func flood_saturation() -> float:
	return flood


func storm_flag() -> bool:
	return storm


func storm_cell() -> Dictionary:
	return storm_cell_row


func next_weather_boundary_h() -> float:
	return weather_boundary_h


# --- doc 10 ----------------------------------------------------------------

func road_intersections() -> Array:
	return intersections


func road_set_edge_speed_mult(tile: Vector2i, mult: float) -> void:
	edge_speed.append({"tile": tile, "mult": mult})


func road_close_edge(tile: Vector2i, duration_h: float, cause: String = "") -> void:
	edge_closed.append({"tile": tile, "duration_h": duration_h, "cause": cause})


# --- doc 03 ----------------------------------------------------------------

func repair_cost(_target_ref: Dictionary, _damage_fraction: float) -> int:
	return repair_cost_value


func vehicle_dispatch_cost(_vehicle_type: String) -> int:
	return dispatch_cost_value


func credit(amount: int, reason: String) -> void:
	credits.append({"amount": amount, "reason": reason})


func debit(amount: int, reason: String) -> bool:
	debits.append({"amount": amount, "reason": reason})
	return true


func difficulty_escalation_mult() -> float:
	return escalation_mult


func difficulty_generation_mult() -> float:
	return generation_mult


# --- doc 02 construction ---------------------------------------------------

func release_crew_from_job(job_id: int, crew_id: String) -> void:
	released_jobs.append({"job_id": job_id, "crew_id": crew_id})
