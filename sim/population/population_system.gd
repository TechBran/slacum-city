class_name PopulationSystem
extends RefCounted
## Aggregate population, occupancy and job fill (doc 09 §2.10, gap G-1).
## No individual citizens (constitution §8). One city-wide job-fill ratio —
## a per-building allocation loop would be order-dependent and break the
## offline coarse path's exactness.

const WORKFORCE_FRACTION: float = 0.55
const OCCUPANCY_RAMP_HOURS: float = 36.0
const ATTRACT_TAU_H: float = 12.0

## City attractiveness A_city ∈ [0.25, 1.00]; relaxes toward A_target.
var attractiveness: float = 1.0
var occupied_population: float = 0.0
var city_population: int = 0
var workforce: float = 0.0
var jobs_capacity: int = 0
var jobs_market: int = 0
var job_fill_city: float = 1.0
var occupancy: Dictionary = {}  # building id -> occ_b (sparse on save)


static func ramp(age_hours: float) -> float:
	return clampf(0.35 + 0.65 * age_hours / OCCUPANCY_RAMP_HOURS, 0.35, 1.0)


static func attractiveness_target(city_stability: float) -> float:
	return clampf((city_stability - 0.35) / 0.50, 0.25, 1.0)


## Advance A_city and recompute all aggregates for one step of dt_h game-hours.
## `buildings`: Array of Dictionaries:
##   {id: String, population: int, jobs: int, residential: bool, civic: bool,
##    state_occupancy: float, age_hours: float}
## `growth_rate_multiplier` comes from doc 03 (tax drag on refill).
func advance(buildings: Array, dt_h: float, city_stability: float,
		growth_rate_multiplier: float = 1.0) -> Dictionary:
	var target := attractiveness_target(city_stability)
	attractiveness += (target - attractiveness) \
			* (1.0 - exp(-dt_h * growth_rate_multiplier / ATTRACT_TAU_H))

	# Pass 1: workforce comes from residential occupancy, which does not
	# depend on job fill — so it resolves before the market ratio.
	occupancy.clear()
	jobs_capacity = 0
	jobs_market = 0
	occupied_population = 0.0
	for b in buildings:
		jobs_capacity += int(b.get("jobs", 0))
		if not bool(b.get("civic", false)):
			jobs_market += int(b.get("jobs", 0))
		if bool(b.get("residential", false)):
			var occ := _occ_residential(b)
			occupancy[String(b["id"])] = occ
			occupied_population += float(int(b.get("population", 0))) * occ
	workforce = occupied_population * WORKFORCE_FRACTION
	job_fill_city = clampf(workforce / maxf(1.0, float(jobs_market)), 0.0, 1.0)

	# Pass 2: revenue buildings additionally scale by the market ratio;
	# civic/utility buildings are always fully staffed (doc 09 §2.10.1).
	for b in buildings:
		var id := String(b["id"])
		if bool(b.get("residential", false)):
			continue
		if bool(b.get("civic", false)):
			occupancy[id] = float(b.get("state_occupancy", 1.0))
		else:
			occupancy[id] = _occ_residential(b) * job_fill_city
	city_population = roundi(occupied_population)
	return {
		"occupied_population": occupied_population,
		"city_population": city_population,
		"workforce": workforce,
		"jobs_capacity": jobs_capacity,
		"jobs_market": jobs_market,
		"job_fill_city": job_fill_city,
	}


func _occ_residential(b: Dictionary) -> float:
	return float(b.get("state_occupancy", 1.0)) \
			* ramp(float(b.get("age_hours", 0.0))) * attractiveness


## Doc 09 §2.10.3 input: punishes both unemployment and unstaffed shops.
func employment_balance() -> float:
	return 1.0 - absf(workforce - float(jobs_market)) \
			/ maxf(maxf(workforce, float(jobs_market)), 1.0)


func occ_of(building_id: String) -> float:
	return float(occupancy.get(building_id, 1.0))


func serialize() -> Dictionary:
	var sparse := {}
	for id in occupancy:
		if absf(float(occupancy[id]) - 1.0) > 0.0001:
			sparse[id] = occupancy[id]
	return {"section_version": 1, "attractiveness": attractiveness, "occupancy": sparse}


func deserialize(data: Dictionary) -> void:
	attractiveness = float(data.get("attractiveness", 1.0))
	occupancy = data.get("occupancy", {})
