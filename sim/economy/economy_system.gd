class_name EconomySystem
extends RefCounted
## The per-game-hour settlement loop (doc 03 §2.1–§2.5), the land market
## (§2.7–§2.8) and the offline yield taper (§2.11).
##
## One tick = one game-hour (constitution §4 cadence "economy per game-hour"):
##   1. per-building revenue `R_b` (§2.2), summed, floored at the city level;
##   2. tariffs, fines (§2.5);
##   3. the recurring expense lines (§2.4);
##   4. `Treasury.settle()` with the single city-wide rounding and the
##      millidollar carry (§2.1 precision rule, report 98 C-15);
##   5. a `BudgetSnapshot`-shaped Dictionary for `ui/` and the WHILE YOU WERE
##      AWAY history.
##
## Offline uses this same entry point (constitution §4 forbids a parallel
## implementation); the only difference is `yield_mult`, which is 1.0 online.
##
## Every number comes from `data/economy.json` through `CostCurves`; the only
## constants declared here are the ones another doc owns and this doc merely
## consumes (doc 10's road decay rates and congestion coupling), which are
## overridable per call.

## doc 10 §2.3 / §2.12, on the RR-3 [0,1] road-condition scale. Doc 10 owns the
## physics and publishes no price; this doc owns the money and publishes no
## decay rate. Passed through `inputs.roads` when doc 10's data file lands.
const DOC10_BASE_DECAY_PER_GAME_DAY := {"AVENUE": 0.0060, "STREET": 0.0090}
const DOC10_CONGESTION_COEFF := 0.75  # decay × (1 + 0.75·c_day) × (1 + wx_wear_day)
const HOURS_PER_GAME_DAY := 24.0

var events: Array[Dictionary] = []

var _curves: CostCurves
var _treasury: Treasury
var _economy: Dictionary = {}
var _tax: Dictionary = {}
var _expenses: Dictionary = {}
var _tariffs: Dictionary = {}
var _land: Dictionary = {}
var _development: Dictionary = {}
var _offline: Dictionary = {}
var _roads: Dictionary = {}


func _init(curves: CostCurves, treasury: Treasury = null) -> void:
	_curves = curves
	_treasury = treasury
	_economy = curves.economy_data()
	_tax = _economy.get("tax", {})
	_expenses = _economy.get("expenses", {})
	_tariffs = _economy.get("tariffs", {})
	_land = _economy.get("land", {})
	_development = _economy.get("development", {})
	_offline = _economy.get("offline", {})
	_roads = _economy.get("roads", {})


func curves() -> CostCurves:
	return _curves


func treasury() -> Treasury:
	return _treasury


func drain_events() -> Array[Dictionary]:
	var out := events
	events = [] as Array[Dictionary]
	return out


# ============================================================ §2.2 tax factors

## `tax_policy_factor = r / TAX_RATE_BASE`, r clamped to the slider range.
func tax_policy_factor(rate: float) -> float:
	var base := float(_tax.get("TAX_RATE_BASE", 0.09))
	var clamped := clampf(rate, float(_tax.get("TAX_RATE_MIN", 0.04)),
			float(_tax.get("TAX_RATE_MAX", 0.16)))
	return clamped / base if base > 0.0 else 1.0


## The doc-09 bill for a rate change (§2.2). Published here, applied there.
func happiness_tax_delta(rate: float) -> float:
	return -(rate - float(_tax.get("TAX_RATE_BASE", 0.09))) \
			* float(_tax.get("TAX_RATE_HAPPINESS_COEFF", 0.0))


func growth_rate_multiplier(rate: float) -> float:
	return 1.0 - (rate - float(_tax.get("TAX_RATE_BASE", 0.09))) \
			* float(_tax.get("TAX_RATE_GROWTH_COEFF", 0.0))


## §2.2 third coupling (doc 92 F-5 / doc 09 amendment T-1): the attractiveness
## CEILING the current rate buys. `growth_rate_multiplier` scales how FAST doc
## 09's `A_city` relaxes; this scales WHAT IT RELAXES TOWARD, which is the half
## that can actually cost a healthy city people.
##
## Priced off `happiness_tax_delta` rather than off the rate a second time — the
## slider is converted to happiness points ONCE, here, and doc 09 spends those
## points on the one scale it already has (report 98's no-double-count rule
## applied to a coupling instead of to a price). Only the punitive half counts:
## `min(0, Δ)`, so cutting tax buys a faster refill (that IS the growth
## multiplier) and never an attractiveness ceiling above the stability one.
## Returns 1.0 at and below `TAX_RATE_BASE`; doc 09 clamps it onto [0.25, 1.00].
func attractiveness_tax_factor(rate: float) -> float:
	return 1.0 + float(_tax.get("TAX_RATE_ATTRACT_PULL", 0.0)) \
			* minf(0.0, happiness_tax_delta(rate)) / 100.0


func tax_rate_change_allowed(hour: int, last_changed_hour: int) -> bool:
	if last_changed_hour < 0:
		return true
	return hour - last_changed_hour >= int(_tax.get("TAX_RATE_COOLDOWN_HOURS", 0))


func f_stability(stability: float) -> float:
	var floor_value := float(_tax.get("STAB_FLOOR", 0.0))
	return floor_value + (1.0 - floor_value) \
			* pow(clampf(stability, 0.0, 1.0), float(_tax.get("STAB_EXP", 1.0)))


func f_happiness(happiness: float) -> float:
	return clampf(1.0 + float(_tax.get("HAPPY_SLOPE", 0.0)) * (happiness - 60.0) / 100.0,
			float(_tax.get("HAPPY_FACTOR_MIN", 0.0)), float(_tax.get("HAPPY_FACTOR_MAX", 2.0)))


func f_condition(condition: float) -> float:
	var floor_value := float(_tax.get("COND_FLOOR", 0.0))
	return floor_value + (1.0 - floor_value) * clampf(condition, 0.0, 1.0)


## `f = floor[class] + (1 - floor[class]) × availability`. A data center with no
## power earns nothing; a house with no power still earns 35% of its power term.
func utility_factor(tax_class: String, channel: String, availability: float) -> float:
	var floors: Dictionary = _tax.get("utility_floors", {}).get(tax_class, {})
	var floor_value := float(floors.get(channel, 0.0))
	return floor_value + (1.0 - floor_value) * clampf(availability, 0.0, 1.0)


## §2.2: fresh buildings ramp from 0.35 to 1.0 over OCCUPANCY_RAMP_HOURS.
## Read as a CAP on doc 09's occupancy: at age 0 a full building still bills 0.35.
func occupancy_ramp_cap(age_hours: float) -> float:
	var ramp_hours := float(_tax.get("OCCUPANCY_RAMP_HOURS", 0.0))
	if ramp_hours <= 0.0:
		return 1.0
	return clampf(0.35 + 0.65 * age_hours / ramp_hours, 0.35, 1.0)


## One building's hourly revenue, with every factor exposed for the UI's
## foregone-by-cause breakdown (§2.6).
## `building`: {type, level, occ, power, water, road, stability, condition, age_hours}
## `context`:  {happiness, policy_factor, m_rev}
func revenue_for_building(building: Dictionary, context: Dictionary) -> Dictionary:
	var type := String(building.get("type", ""))
	var level := int(building.get("level", 1))
	var base := float(_curves.base_tax(type, level))
	var tax_class := _curves.class_of(type)
	var occ := clampf(float(building.get("occ", 1.0)), 0.0, 1.0)
	if building.has("age_hours"):
		occ = minf(occ, occupancy_ramp_cap(float(building["age_hours"])))
	var policy := float(context.get("policy_factor", 1.0))
	var m_rev := float(context.get("m_rev", 1.0))
	var potential := base * occ * policy * m_rev
	var fp := utility_factor(tax_class, "power", float(building.get("power", 1.0)))
	var fw := utility_factor(tax_class, "water", float(building.get("water", 1.0)))
	var fr := utility_factor(tax_class, "road", float(building.get("road", 1.0)))
	var fs := f_stability(float(building.get("stability", 1.0)))
	var fh := f_happiness(float(context.get("happiness", 60.0)))
	var fc := f_condition(float(building.get("condition", 1.0)))
	return {
		"type": type, "level": level, "class": tax_class, "base_tax": base, "occ": occ,
		"f_power": fp, "f_water": fw, "f_road": fr, "f_stability": fs,
		"f_happiness": fh, "f_condition": fc, "policy_factor": policy, "m_rev": m_rev,
		"potential": potential, "revenue": potential * fp * fw * fr * fs * fh * fc,
	}


# ========================================================== §2.4 expense lines

## `station_upkeep(type, L) = round(l1 × DEPT_LEVEL_GROWTH^(L-1))`; a mothballed
## station pays MOTHBALL_UPKEEP_FRACTION of it and provides zero coverage.
func station_upkeep(station_type: String, level: int = 1, mothballed: bool = false) -> float:
	var l1 := float(_expenses.get("station_upkeep_l1", {}).get(station_type, 0.0))
	if l1 <= 0.0:
		return 0.0
	var growth := float(_expenses.get("DEPT_LEVEL_GROWTH", 1.0))
	var upkeep := float(CostCurves.round_half_up(l1 * pow(growth, maxi(level, 1) - 1)))
	if mothballed:
		upkeep *= float(_expenses.get("MOTHBALL_UPKEEP_FRACTION", 0.0))
	return upkeep


## doc 03 §2.10 player-driven rescue: reactivating a mothballed station costs
## `0.60 × station_upkeep × 24` = MOTHBALL_REACTIVATE_HOURS_OF_UPKEEP × upkeep.
func mothball_reactivation_cost(station_type: String, level: int = 1) -> int:
	return CostCurves.round_half_up(station_upkeep(station_type, level)
			* float(_expenses.get("MOTHBALL_REACTIVATE_HOURS_OF_UPKEEP", 0.0)))


## True where `E_grid` / `E_water` already bill the facility's O&M, so the
## department line is staffing only (report 98 RR-16).
func station_upkeep_is_staffing_only(station_type: String) -> bool:
	return (_expenses.get("station_upkeep_is_staffing_only", []) as Array).has(station_type)


## §2.4 `E_grid` — the ONLY recurring electrical-plant cost (report 98 C-12).
## `inventory` is `PowerGrid.grid_inventory()`: {nodes, lines, plants}.
func e_grid(inventory: Dictionary) -> float:
	var node_rate := float(_expenses.get("GRID_MAINT_PER_MW_HOUR", 0.0))
	var line_rate := float(_expenses.get("LINE_MAINT_PER_KM_HOUR", 0.0))
	var plant_rate := float(_expenses.get("PLANT_OM_PER_MW_HOUR", 0.0))
	var penalty := float(_expenses.get("ASSET_CONDITION_PENALTY_COEFF", 0.0))
	var total := 0.0
	for node in inventory.get("nodes", []):
		var record: Dictionary = node
		total += float(record.get("rated_mva", 0.0)) * node_rate \
				* (1.0 + penalty * (1.0 - float(record.get("condition", 1.0))))
	for line in inventory.get("lines", []):
		var record: Dictionary = line
		total += float(record.get("line_km", 0.0)) * line_rate \
				* (1.0 + penalty * (1.0 - float(record.get("condition", 1.0))))
	for plant in inventory.get("plants", []):
		var record: Dictionary = plant
		# The plant carries the same condition penalty its own nodes and lines
		# carry (Wave 17, doc 03 §2.4, doc 93 §Y5). It was the one row of this
		# inventory left flat, and a half-dead plant burning the same fuel to
		# make less power is precisely what the coefficient means. A record with
		# no `condition` reads 1.00 and bills what it billed before.
		total += float(record.get("plant_capacity_mw", 0.0)) * plant_rate \
				* (1.0 + penalty * (1.0 - clampf(
						float(record.get("condition", 1.0)), 0.0, 1.0)))
	return total


## §2.4 `E_fuel_generation`. `generation`: [{plant_type, mwh, level}].
func e_fuel_generation(generation: Array) -> float:
	var prices: Dictionary = _expenses.get("FUEL_PRICE_PER_MWH", {})
	var efficiency: Dictionary = _expenses.get("plant_efficiency_mult", {})
	var total := 0.0
	for entry in generation:
		var record: Dictionary = entry
		var plant_type := String(record.get("plant_type", "gas"))
		var level := maxi(int(record.get("level", 1)), 1)
		var mult := 1.0
		var ladder: Array = efficiency.get(plant_type, [])
		if level <= ladder.size():
			mult = float(ladder[level - 1])
		total += float(record.get("mwh", 0.0)) * float(prices.get(plant_type, 0.0)) * mult
	return total


## §2.4 `E_water` (doc 05 supplies the volumes).
func e_water(water: Dictionary) -> float:
	return float(water.get("m3_treated", 0.0)) * float(_expenses.get("WATER_TREAT_COST_PER_M3", 0.0)) \
			+ float(water.get("main_km", 0.0)) \
			* float(_expenses.get("WATER_MAIN_MAINT_PER_KM_HOUR", 0.0)) \
			* (1.0 + float(_expenses.get("ASSET_CONDITION_PENALTY_COEFF", 0.0))
					* (1.0 - float(water.get("main_condition", 1.0)))) \
			+ float(water.get("pump_capacity_m3h", 0.0)) \
			* float(_expenses.get("PUMP_OM_PER_M3H_HOUR", 0.0))


## §2.4 `E_roads_repair` (report 98 RR-2 / RR-13) — the *accrual* the auto-repair
## policy realises as lumpy one-off jobs. Roads carry no standing upkeep.
## `roads`: {tiles: {AVENUE, STREET}, c_day, wx_wear_day, base_decay_per_game_day}
func e_roads_repair(roads: Dictionary, m_repair: float = 1.0) -> float:
	var tiles: Dictionary = roads.get("tiles", {})
	var decay_rates: Dictionary = roads.get("base_decay_per_game_day",
			DOC10_BASE_DECAY_PER_GAME_DAY)
	var congestion := 1.0 + DOC10_CONGESTION_COEFF * float(roads.get("c_day", 0.0))
	var weather := 1.0 + float(roads.get("wx_wear_day", 0.0))
	var price := float(_expenses.get("REPAIR_COST_PER_CAPITAL", 0.0))
	var total := 0.0
	for road_class in tiles:
		var count := float(tiles[road_class])
		var capital := float(_curves.capital_value_road(String(road_class)))
		var decay_per_hour := float(decay_rates.get(road_class, 0.0)) * congestion * weather \
				/ HOURS_PER_GAME_DAY
		total += count * capital * decay_per_hour * price * m_repair
	return total


## §2.4 `E_fleet` + `E_fuel_vehicle`. `vehicles`: [{type, dispatched, km_this_hour}].
func e_fleet(vehicles: Array) -> float:
	var total := 0.0
	for entry in vehicles:
		var record: Dictionary = entry
		var row := _curves.vehicle_row(String(record.get("type", "")))
		if row.is_empty():
			continue
		var upkeep := float(row.get("upkeep", 0.0))
		if bool(record.get("dispatched", false)):
			upkeep *= float(row.get("active_mult", 1.0))
		total += upkeep
	return total


func e_fuel_vehicle(vehicles: Array, fuel_weather_mult: float = 1.0) -> float:
	var per_km: Dictionary = _expenses.get("FUEL_COST_PER_KM", {})
	var total := 0.0
	for entry in vehicles:
		var record: Dictionary = entry
		var row := _curves.vehicle_row(String(record.get("type", "")))
		if row.is_empty():
			continue
		total += float(record.get("km_this_hour", 0.0)) \
				* float(per_km.get(String(row.get("fuel_class", "light")), 0.0))
	return total * fuel_weather_mult


# ============================================================ the settlement

## One game-hour. Returns the full breakdown (`BudgetSnapshot` shape) and, when a
## `Treasury` is attached, applies the net through it with the millidollar carry.
##
## `inputs` (every key optional; defaults are the nominal/no-op value):
##   hour, buildings[], happiness, tax_rate, difficulty{M_rev,M_exp,M_repair,
##   REV_FLOOR_FRACTION}, yield_mult, grid_inventory{}, generation[],
##   delivered_mwh, water{}, stations[], vehicles[], fuel_weather_mult, roads{},
##   city_services{dispatch,street}, founding_assistance, debt_interest,
##   apply_to_treasury
##
## *(`police_incidents_resolved` is GONE — report 98 RR-78. It fed a `fines`
## line that was doc 06's `reward_base` under another name, metered by
## `CitySim.HELD_FINE_RATE` so it printed a flat $3.00/gh forever. The live
## measurement replaces it: `city_services`.)*
##
## **Which line takes which difficulty knob** (doc 03 §2.4, doc 93 §N1). Three
## groups, and the rule is *one knob per line, never two*:
##   * seven recurring lines take `M_exp` — maint, departments, fleet, vehicle
##     fuel, grid, generation fuel, water;
##   * `roads_repair` takes `M_repair` and NOT `M_exp`, because it is a repair
##     price booked as a recurring accrual, and the policy that realises it pays
##     `repair_cost_road(…, M_repair)`;
##   * `debt` takes neither — its difficulty is the APR.
## `M_rev` is the TAX multiplier and reaches `revenue_for_building()` only — doc
## 03 §2.2 puts it inside the per-building formula and inside the revenue floor,
## and §2.5, which authors every non-tax line, never mentions it. Two of those
## three lines was §9 item 6b's HELD metering constant
## (`CitySim.HELD_DELIVERED_MWH`), so scaling it by difficulty would price a
## placeholder; `water_tariff` is 0.41 % of founding gross. Doc 93 §N2 rules it
## and carries the re-open condition — **and RR-78 discharged half of it**: the
## `fines` half of the held pair is now the live `city_services` line, and
## `city_services` and `assistance` are outside `M_rev` for the same §2.5 reason
## every other non-tax line is.
func settle_hour(inputs: Dictionary) -> Dictionary:
	var hour := int(inputs.get("hour", 0))
	var difficulty := _resolve_difficulty(inputs)
	var m_rev := float(difficulty.get("M_rev", 1.0))
	var m_exp := float(difficulty.get("M_exp", 1.0))
	var m_repair := float(difficulty.get("M_repair", 1.0))
	var rev_floor := float(difficulty.get("REV_FLOOR_FRACTION", 0.0))
	var yield_mult := float(inputs.get("yield_mult", 1.0))
	var rate := float(inputs.get("tax_rate", _tax.get("TAX_RATE_BASE", 0.09)))
	var context := {
		"happiness": float(inputs.get("happiness", 60.0)),
		"policy_factor": tax_policy_factor(rate),
		"m_rev": m_rev,
	}

	# --- §2.2 revenue -----------------------------------------------------
	var per_building: Array[Dictionary] = []
	var tax_by_class: Dictionary = {}
	var potential := 0.0
	var actual := 0.0
	for entry in inputs.get("buildings", []):
		var record: Dictionary = entry
		if _curves.base_tax(String(record.get("type", "")), int(record.get("level", 1))) == 0:
			continue  # civic and utility buildings carry base_tax = 0 (§2.2)
		var result := revenue_for_building(record, context)
		per_building.append(result)
		potential += float(result["potential"])
		actual += float(result["revenue"])
		var tax_class := String(result["class"])
		tax_by_class[tax_class] = float(tax_by_class.get(tax_class, 0.0)) + float(result["revenue"])
	# Layer 1 of the anti-death-spiral ladder: city aggregate only. Per-building
	# numbers stay brutally honest so the cascade remains legible (§2.2 / §2.10).
	var floored := maxf(actual, rev_floor * potential)
	var floor_applied := floored > actual + 1e-9
	if floor_applied and not per_building.is_empty():
		var scale := floored / maxf(actual, 1e-9)
		for tax_class in tax_by_class:
			tax_by_class[tax_class] = float(tax_by_class[tax_class]) * scale

	# --- §2.5 non-tax revenue --------------------------------------------
	var water: Dictionary = inputs.get("water", {})
	var power_tariff := float(inputs.get("delivered_mwh", 0.0)) \
			* float(_tariffs.get("POWER_TARIFF_PER_MWH", 0.0))
	var water_tariff := float(water.get("delivered_m3", 0.0)) \
			* float(_tariffs.get("WATER_TARIFF_PER_M3", 0.0))
	# --- §2.5 city services, and §2.5a the founding grant (RR-78 / RR-79) -----
	# `city_services` is CASH ALREADY IN THE TREASURY: doc 06 pays a resolved
	# incident the moment it resolves and doc 12 pays a collected street
	# opportunity the moment it is tapped, because the player has to see the
	# number move. It is still operating revenue, so it is reported on its own
	# line here and then subtracted from what the settlement moves in cash, five
	# lines below. Exactly one dollar, exactly one line; only the moment differs.
	#
	# It REPLACES the `fines` line, which was doc 03's half of a dollar doc 06
	# was already paying (report 98 RR-78 — the ruling doc 06 asked for in Wave 1
	# and doc 93 §N1 point 4 wrote the re-open condition for). `fines` was a held
	# metering constant standing in until doc 06 published real resolutions; it
	# has, and this is them.
	var services: Dictionary = inputs.get("city_services", {})
	var services_total := 0.0
	for key in services:
		services_total += float(services[key])
	var assistance := float(inputs.get("founding_assistance", 0.0))
	var gross_revenue := floored + power_tariff + water_tariff + assistance

	# --- §2.4 expenses ----------------------------------------------------
	# **`E_building_maint` STAYS, and doc 93 §Y1 says why it stays** (Wave 17).
	# The first draft of that ruling retired it: the loop below skips every row
	# where `is_revenue_producing(type)` is false — C-08, so a civic shell is not
	# billed beside its own department line — and that predicate is exactly the
	# four `REVENUE_CLASSES`, so the line bills exactly the buildings the city
	# does not own. It reads like the city paying a landlord's repair bill.
	#
	# **It is not.** It is the city's cost of SERVING a building — the reading
	# C-08 itself implies, since the civic exclusion is "those are billed by
	# their own O&M lines", not "the city only pays for what it owns" — and it
	# rises as the building wears because a worn building costs more to serve.
	# The thing the 2026-09-01 playtest asked to move to the owner is the lumpy,
	# TAPPED repair, and that is what `E_OWNER_MAINTAINED` moves.
	#
	# Retiring it was measured before it was believed, and the measurement is why
	# it is here: doc 92 §43.8. With this line gone AND private stock kept up by
	# its owners, `tools/measure_insolvency.gd` put `do_nothing` on `standard` at
	# game-day 176 against gate 29's ruled 69, and `casual` never went insolvent
	# inside 200 game-days at all — "a preset on which standing still never costs
	# anything is a preset with no game in it", in the gate's own words.
	var maint_rate := float(_expenses.get("BUILDING_MAINT_RATE", 0.0))
	var maint_penalty := float(_expenses.get("MAINT_CONDITION_PENALTY", 0.0))
	var building_maint := 0.0
	for entry in inputs.get("buildings", []):
		var record: Dictionary = entry
		var type := String(record.get("type", ""))
		if not _curves.is_revenue_producing(type):
			continue  # civic/utility are covered by their department / O&M lines (C-08)
		var capital := float(_curves.capital_value(type, int(record.get("level", 1))))
		building_maint += capital * maint_rate \
				* (1.0 + maint_penalty * (1.0 - float(record.get("condition", 1.0))))

	# **The station's own condition reaches its own bill** (Wave 17, doc 03 §2.4,
	# doc 93 §Y5). `ASSET_CONDITION_PENALTY_COEFF` has always been applied to the
	# two other classes of asset the city owns — a worn grid node and a worn
	# water main both cost more per hour, on exactly this coefficient — and the
	# station line was the one that stayed flat: a police station at condition
	# 0.20 was billed the same staffing as one at 1.00. A row that carries no
	# `condition` reads 1.00 and bills exactly what it billed before.
	var asset_penalty := float(_expenses.get("ASSET_CONDITION_PENALTY_COEFF", 0.0))
	var departments := 0.0
	for entry in inputs.get("stations", []):
		var record: Dictionary = entry
		departments += station_upkeep(String(record.get("type", "")),
				int(record.get("level", 1)), bool(record.get("mothballed", false))) \
				* (1.0 + asset_penalty
						* (1.0 - clampf(float(record.get("condition", 1.0)), 0.0, 1.0)))

	var vehicles: Array = inputs.get("vehicles", [])
	var fleet := e_fleet(vehicles)
	var vehicle_fuel := e_fuel_vehicle(vehicles, float(inputs.get("fuel_weather_mult", 1.0)))
	var grid := e_grid(inputs.get("grid_inventory", {}))
	var generation_fuel := e_fuel_generation(inputs.get("generation", []))
	var water_expense := e_water(water)
	var roads_repair := e_roads_repair(inputs.get("roads", {}), m_repair)

	var recurring := building_maint + departments + fleet + vehicle_fuel + grid \
			+ generation_fuel + water_expense
	var austerity_mult := _treasury.austerity_expense_mult() if _treasury != null else 1.0
	recurring *= m_exp * austerity_mult
	# E_roads_repair carries its own difficulty term (`M_repair`, applied inside
	# `e_roads_repair` above) and is NOT swept by `M_exp` — the same exclusion
	# `E_debt` gets two lines below, for the same reason (doc 03 §2.4, doc 93
	# §N1). It IS swept by austerity and by the offline taper, because those are
	# not difficulty. The reason it is not swept by M_exp: this line is an ACCRUAL
	# against a payment, and the payment is C-16's one repair price —
	# `repair_cost_road(class, damage_fraction, M_repair)`, which has no `M_exp`
	# anywhere in it. An accrual billed at M_repair × M_exp against a payment
	# priced at M_repair is the double count RR-2 and C-16 exist to stop, one knob
	# down. Hash-neutral on the DEFAULT preset by construction: `M_exp` is 1.00 on
	# `standard`, so this line's arithmetic is unmoved.
	recurring += roads_repair * austerity_mult
	# E_debt carries its own difficulty term (the APR) and is not scaled by M_exp,
	# austerity or the offline taper: interest accrues on the real balance.
	var debt := float(inputs.get("debt_interest",
			_treasury.debt_interest_per_hour() if _treasury != null else 0))

	# --- §2.11 offline taper: revenue and recurring expenses, identically --
	# The taper is doc 08's offline discount on what the city EARNS while nobody
	# is watching. `services_total` is outside it because it is not an accrual at
	# all — it is dollars the treasury already holds, at face value, from the
	# moment they were paid.
	var revenue_total := gross_revenue * yield_mult + services_total
	var expense_total := recurring * yield_mult + debt

	var snapshot := {
		"hour": hour,
		# Wave 17 (doc 93 §Y4, doc 92 §43.2): whole game-days of founding
		# assistance still to come, 0 once the taper has retired. It lives at the
		# TOP of the snapshot and not inside `revenue`, because every key in
		# `revenue` is a dollar figure a budget sheet sums and this one is a count.
		"assistance_days_left": int(inputs.get("founding_assistance_days_left", 0)),
		"revenue": {
			"tax": floored * yield_mult,
			"tax_by_class": tax_by_class,
			"power_tariff": power_tariff * yield_mult,
			"water_tariff": water_tariff * yield_mult,
			"city_services": services_total,
			"city_services_by_source": services.duplicate(),
			"assistance": assistance * yield_mult,
			"gross": revenue_total,
		},
		"expenses": {
			"building_maint": building_maint * m_exp * austerity_mult * yield_mult,
			"departments": departments * m_exp * austerity_mult * yield_mult,
			"fleet": fleet * m_exp * austerity_mult * yield_mult,
			"vehicle_fuel": vehicle_fuel * m_exp * austerity_mult * yield_mult,
			"grid": grid * m_exp * austerity_mult * yield_mult,
			"generation_fuel": generation_fuel * m_exp * austerity_mult * yield_mult,
			"water": water_expense * m_exp * austerity_mult * yield_mult,
			"roads_repair": roads_repair * austerity_mult * yield_mult,
			"debt": debt,
			"total": expense_total,
		},
		"potential_tax": potential * yield_mult,
		"foregone": maxf(0.0, (potential - floored) * yield_mult),
		"revenue_floor_applied": floor_applied,
		"net": revenue_total - expense_total,
		"yield_mult": yield_mult,
		"buildings": per_building,
	}

	if _treasury != null and bool(inputs.get("apply_to_treasury", true)):
		# `services_total` is netted out because that cash moved when it was
		# earned. Settling it again would credit the same dollar twice — which
		# is the exact mistake RR-78 exists to end.
		snapshot["settled"] = _treasury.settle(
				revenue_total - services_total, expense_total)
	events.append({"type": &"economy_hour_settled", "hour": hour,
			"gross": revenue_total, "expense": expense_total,
			"city_services": services_total, "assistance": assistance * yield_mult,
			"net": revenue_total - expense_total})
	return snapshot


# ================================================== §2.7 land purchase price

## The seven-term price of one 16×16 land block. `inputs` is doc 09's
## `LandPriceInputs` bundle: {d, dev_terrain, risk_index, waterfront_edges,
## arterial_connections, prestige, elevation_norm, blocks_owned, m_land,
## non_adjacent}.
func land_price(inputs: Dictionary) -> int:
	return CostCurves.round_half_up(land_price_raw(inputs)
			/ float(_land.get("PRICE_ROUNDING", 100))) * int(_land.get("PRICE_ROUNDING", 100))


## The same price before `round_to_100` — the doc's worked examples quote it
## (D 12,395.40 → $12,400; E 6,700.87 → $6,700).
func land_price_raw(inputs: Dictionary) -> float:
	var base := float(_land.get("LAND_BASE", 0.0))
	var d := maxf(1.0, float(inputs.get("d", 1.0)))
	var distance := float(_land.get("DIST_FLOOR", 0.0)) \
			+ (1.0 - float(_land.get("DIST_FLOOR", 0.0))) \
			* exp(-(d - 1.0) / float(_land.get("DIST_DECAY", 1.0)))
	var terrain := float((_land.get("terrain_mult", {}) as Dictionary).get(
			String(inputs.get("dev_terrain", "flat")), 1.0))
	var risk := 1.0 - float(_land.get("RISK_DISCOUNT", 0.0)) \
			* clampf(float(inputs.get("risk_index", 0.0)), 0.0, 1.0)
	var waterfront := 1.0 + float(_land.get("WATERFRONT_PREMIUM", 0.0)) \
			* (float(inputs.get("waterfront_edges", 0)) / 4.0)
	var access := 1.0 + float(_land.get("ROAD_ADJ_PREMIUM", 0.0)) \
			* float(inputs.get("arterial_connections", 0))
	var proximity := 1.0 + float(_land.get("PROX_COEFF", 0.0)) \
			* float(inputs.get("prestige", 0.0))
	var elevation := 1.0 + float(_land.get("ELEV_COEFF", 0.0)) \
			* float(inputs.get("elevation_norm", 0.0))
	var escalation := escalation_factor(int(inputs.get("blocks_owned",
			_land.get("STARTER_BLOCKS_FREE", 0))))
	var price := base * distance * terrain * risk * waterfront * access * proximity \
			* elevation * escalation * float(inputs.get("m_land", 1.0))
	if bool(inputs.get("non_adjacent", false)):
		price *= float(_land.get("NONADJACENT_PREMIUM", 1.0))
	return price


## The growth brake: `min(1 + LAND_ESCALATION × max(0, owned - free), ESCALATION_CAP)`.
func escalation_factor(blocks_owned: int) -> float:
	return minf(1.0 + float(_land.get("LAND_ESCALATION", 0.0))
			* float(maxi(0, blocks_owned - int(_land.get("STARTER_BLOCKS_FREE", 0)))),
			float(_land.get("ESCALATION_CAP", 1.0)))


# ============================================= §2.8 land development phases

func development_phases() -> Array:
	return _development.get("phases", [])


func development_phase_index(phase: Variant) -> int:
	if phase is int:
		return int(phase)
	var phases: Array = development_phases()
	for index in phases.size():
		if String((phases[index] as Dictionary).get("id", "")) == String(phase):
			return index
	return -1


## `phase_cost = round(PHASE_BASE × terrain_mult × (1 + DIST_DEV_COEFF × d) ×
##                     access_mult × M_dev)`; `access_mult` applies to
## `road_install` only. `phase` is the phase id or its 0-based index.
func development_phase_cost(phase: Variant, dev_terrain: String, d: float = 0.0,
		arterial_connections: int = 0, m_dev: float = 1.0) -> int:
	var index := development_phase_index(phase)
	var phases: Array = development_phases()
	if index < 0 or index >= phases.size():
		return 0
	var row: Dictionary = phases[index]
	var terrain_row: Array = (_development.get("terrain_phase_mult", {}) as Dictionary).get(
			dev_terrain, [])
	var terrain := float(terrain_row[index]) if index < terrain_row.size() else 1.0
	var access := 1.0
	if String(row.get("id", "")) == "road_install":
		access = 1.0 - float(_development.get("ROAD_ACCESS_DISCOUNT_PER_CONNECTION", 0.0)) \
				* float(arterial_connections)
	return CostCurves.round_half_up(float(row.get("base", 0)) * terrain
			* (1.0 + float(row.get("dist_coeff", 0.0)) * d) * access * m_dev)


## All six phases, summed — the "Est. development" half of the land TCO the
## purchase dialog must show (§2.8).
func development_total_cost(dev_terrain: String, d: float = 0.0,
		arterial_connections: int = 0, m_dev: float = 1.0) -> int:
	var total := 0
	for index in development_phases().size():
		total += development_phase_cost(index, dev_terrain, d, arterial_connections, m_dev)
	return total


# ================================================== §2.11 offline yield taper

## `yield_mult(h) = 1.0` for `h ≤ OFF_FULL`, else `exp(-(h - OFF_FULL) / OFF_TAU)`.
## `h` is `ctx.catchup_index` — this doc keeps no absence counter (C-20).
func offline_yield_mult(catchup_index: float, off_tau_hours: float = -1.0) -> float:
	var full := float(_offline.get("OFF_FULL_HOURS", 0.0))
	var tau := off_tau_hours if off_tau_hours > 0.0 else _off_tau_hours()
	if catchup_index <= full:
		return 1.0
	return exp(-(catchup_index - full) / tau)


## Effective earning hours across an absence of `H` game-hours:
## `E(H) = H` for `H ≤ OFF_FULL`, else `OFF_FULL + OFF_TAU × (1 - e^(-(H-OFF_FULL)/OFF_TAU))`.
func offline_effective_hours(absence_hours: float, off_tau_hours: float = -1.0) -> float:
	var full := float(_offline.get("OFF_FULL_HOURS", 0.0))
	var tau := off_tau_hours if off_tau_hours > 0.0 else _off_tau_hours()
	if absence_hours <= full:
		return absence_hours
	return full + tau * (1.0 - exp(-(absence_hours - full) / tau))


## §2.11's taper constant is a DIFFICULTY knob (§2.9: casual 120 / standard 90 /
## hard 75 / crisis 60), so it comes off the live `economic` row through the
## treasury — the same place `M_rev` and the revenue floor come from — and no
## longer off `data/economy.json`, which stopped carrying it when
## `data/difficulty.json` shipped. A caller may still pass an explicit tau; doc
## 08's catch-up planner does, when it is asking a what-if.
func _off_tau_hours() -> float:
	return float(_resolve_difficulty({}).get("OFF_TAU_HOURS", 1.0))


## §2.11: one-off offline costs are capped, and damage beyond it is simply not
## billed — the assets stay broken and are reported on return.
func offline_oneoff_cap(treasury_at_close: int, offline_net_revenue: float,
		cap_fraction: float) -> int:
	return CostCurves.round_half_up(cap_fraction
			* (float(treasury_at_close) + offline_net_revenue))


# ------------------------------------------------------------------ plumbing

func _resolve_difficulty(inputs: Dictionary) -> Dictionary:
	var resolved: Dictionary = _treasury.difficulty() if _treasury != null \
			else Treasury.DIFFICULTY_STANDARD.duplicate()
	var overrides: Dictionary = inputs.get("difficulty", {})
	for key in overrides:
		resolved[key] = overrides[key]
	return resolved
