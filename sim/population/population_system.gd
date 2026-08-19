class_name PopulationSystem
extends RefCounted
## Aggregate population, occupancy and job fill (doc 09 §2.10, gap G-1).
## No individual citizens (constitution §8). One city-wide job-fill ratio —
## a per-building allocation loop would be order-dependent and break the
## offline coarse path's exactness.

const WORKFORCE_FRACTION: float = 0.55
const OCCUPANCY_RAMP_HOURS: float = 36.0
const ATTRACT_TAU_H: float = 12.0

## §2.10.2 tax-growth coupling (doc 09 amendment T-1). `A_target` is the MOST
## BINDING of three ceilings — stability, lived happiness, tax burden — never
## their product: a city is not punished twice for one discontent, which is what
## keeps the tax term from double-counting itself through `happiness`.
const ATTRACT_FLOOR: float = 0.25
## Happiness below this reference costs residents. 60 is doc 09 §2.10.3's own
## baseline and the pivot of doc 03's `f_happiness`, so an average city is
## attractiveness-neutral exactly as it is revenue-neutral.
const ATTRACT_HAPPINESS_REF: float = 60.0
## Attractiveness lost per happiness point below the reference, ÷100. Authored
## to the same value as doc 03's `tax.TAX_RATE_ATTRACT_PULL` because both act on
## happiness POINTS; the two are independently ownable and neither reads the
## other (doc 09 owns the mapping, doc 03 owns the tax price).
const ATTRACT_HAPPINESS_PULL: float = 1.30
## The value that makes the happiness ceiling a no-op for callers that have no
## happiness signal (every pre-T-1 call site, and the static worked examples).
const ATTRACT_NEUTRAL_HAPPINESS: float = 100.0

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


## §2.10.2 ceiling 1 — stability. Unchanged by T-1, so every published worked
## example (t0 → 1.00, the `F_SOUTH` 0.60 → 0.50 exodus) still reads the same.
static func stability_ceiling(city_stability: float) -> float:
	return clampf((city_stability - 0.35) / 0.50, ATTRACT_FLOOR, 1.0)


## §2.10.2 ceiling 2 — lived happiness (doc 09 §2.10.3's H). Saturated at and
## above the reference: a happy city cannot exceed the stability ceiling, it can
## only fail to be dragged below it.
static func happiness_ceiling(happiness: float) -> float:
	return clampf(1.0 + ATTRACT_HAPPINESS_PULL
			* minf(0.0, happiness - ATTRACT_HAPPINESS_REF) / 100.0, ATTRACT_FLOOR, 1.0)


## §2.10.2 (amendment T-1) — the attractiveness ceiling, as the most binding of
## three constraints:
##
##     A_target = min( stability_ceiling(S), happiness_ceiling(H), tax_factor )
##
## `tax_factor` is doc 03's `EconomySystem.attractiveness_tax_factor(rate)`,
## which prices the slider off `happiness_tax_delta` — the rate is read once in
## the whole coupling. `min` and not a product: the tax bill already shows up
## inside H twelve game-hours later, and stacking the two would bill the same
## discontent twice. Both terms carry the same pull, so the crossover is one
## line — happiness binds once it has fallen further below the reference than
## the tax bill itself. Defaults are the neutral city, so a caller with no
## happiness or tax signal gets the pre-T-1 stability-only ceiling.
static func attractiveness_target(city_stability: float,
		happiness: float = ATTRACT_NEUTRAL_HAPPINESS,
		tax_factor: float = 1.0) -> float:
	return minf(minf(stability_ceiling(city_stability), happiness_ceiling(happiness)),
			clampf(tax_factor, ATTRACT_FLOOR, 1.0))


## Advance A_city and recompute all aggregates for one step of dt_h game-hours.
## `buildings`: Array of Dictionaries:
##   {id: String, population: int, jobs: int, residential: bool, civic: bool,
##    state_occupancy: float, age_hours: float}
## `growth_rate_multiplier` comes from doc 03 (tax drag on the relaxation RATE);
## `happiness` and `tax_factor` set the TARGET the relaxation walks toward
## (§2.10.2 amendment T-1). Rate and target are different levers on purpose: at
## the bottom detent the city refills 40 % faster toward the same ceiling, and at
## the top detent it empties slowly toward a lower one.
func advance(buildings: Array, dt_h: float, city_stability: float,
		growth_rate_multiplier: float = 1.0,
		happiness: float = ATTRACT_NEUTRAL_HAPPINESS,
		tax_factor: float = 1.0) -> Dictionary:
	var target := attractiveness_target(city_stability, happiness, tax_factor)
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
		"attractiveness": attractiveness,
		"attractiveness_target": target,
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
