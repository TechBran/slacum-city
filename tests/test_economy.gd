extends SimTest
## Doc 03 (economy, taxes, land market & difficulty) — P0-19..P0-22.
##
## Every worked example and published anchor doc 03 states that this layer can
## reproduce: the §2.2 tax chain (examples A/B/C), the §2.3 cost curves and the
## house payback chain doc 02 §2.2 re-derives, the $686/gh starter anchor, the
## §2.7 land price (examples D and E), §2.8's development phases (example F),
## §2.4's `E_grid` on doc 09's real starter inventory through
## `PowerGrid.grid_inventory()`, the §2.12 founding ledger, §2.5 repair pricing,
## the §2.1 millidollar carry, §2.11's taper and §2.10's recovery ladder.

const ECONOMY_PATH := "res://data/economy.json"
const BUILDING_ECONOMY_PATH := "res://data/building_economy.json"
const STARTER_CITY_PATH := "res://data/starter_city.json"

# doc 03 §2.12: doc 09's starter city, the mix report 98 C-11 restored.
const STARTER_MIX := [["house", 18], ["store", 5], ["apartment", 3], ["office", 1]]
const STARTER_STABILITY := 0.9475  # doc 09 t0 city_stability
const STARTER_HAPPINESS := 82.0  # doc 09 t0 H (data/starter_city.json population.happiness)

var _curves_cache: CostCurves = null


func _curves() -> CostCurves:
	if _curves_cache == null:
		_curves_cache = CostCurves.load_from_files(BUILDING_ECONOMY_PATH, ECONOMY_PATH)
	return _curves_cache


func _system(treasury: Treasury = null) -> EconomySystem:
	return EconomySystem.new(_curves(), treasury)


# =========================================================== data + loader

func test_data_files_load_clean() -> void:
	var curves := _curves()
	assert_true(curves.is_valid(), "CostCurves errors: " + ", ".join(curves.errors))
	assert_eq(curves.schema_version(), 1)
	assert_eq(curves.ids().size(), 14, "doc 03 §2.13(a) costs 14 archetypes")


func test_economy_json_carries_the_locked_constants() -> void:
	var economy: Variant = JSON.parse_string(FileAccess.get_file_as_string(ECONOMY_PATH))
	assert_true(economy is Dictionary, "data/economy.json parses")
	var data: Dictionary = economy
	assert_almost_eq(float(data["tax"]["TAX_LEVEL_GROWTH"]), 2.15)
	assert_almost_eq(float(data["upgrades"]["UPG_COEFF"]), 1.15)
	assert_almost_eq(float(data["upgrades"]["UPG_GROWTH"]), 2.55)
	assert_almost_eq(float(data["expenses"]["REPAIR_COST_PER_CAPITAL"]), 0.85)
	assert_almost_eq(float(data["expenses"]["BUILDING_MAINT_RATE"]), 0.00040, 1e-9)
	# Wave 17 (doc 93 §Y1, doc 92 §43.8): the ownership ruling was drafted to
	# retire this line and the retirement was WITHDRAWN on the measurement — with
	# it gone, `do_nothing` on `standard` survived to game-day 176 against gate
	# 29's ruled 69. The constant is pinned here so a second attempt has to read
	# the note in `data/economy.json` first.
	assert_almost_eq(float(data["expenses"]["MAINT_CONDITION_PENALTY"]), 1.5, 1e-9)
	assert_almost_eq(float(data["roads"]["ROAD_REPAIR_CAPITAL_FRACTION"]), 0.20)
	assert_eq(int(data["land"]["LAND_BASE"]), 9000)
	# report 98 C-59: the knob is deleted, not defaulted.
	assert_false(data.has("manual_collection"), "economy.manual_collection must not exist")
	assert_false((data["tax"] as Dictionary).has("manual_collection"))
	# report 98 C-17: no difficulty scalar lives in this file.
	assert_false(data.has("difficulty"), "difficulty moved to data/difficulty.json (C-17)")
	# report 98 RR-7: the demand-growth requirement is an exclusive floor.
	assert_almost_eq(float(data["upgrades"]["REQUIRED_MIN_DEMAND_LEVEL_GROWTH"]), 2.15)
	assert_true(bool(data["upgrades"]["REQUIRED_MIN_DEMAND_LEVEL_GROWTH_EXCLUSIVE"]))


func test_generated_columns_match_curves() -> void:
	# doc 03 §7 test 8 — regenerate and diff, tolerance ±$1 per cell (RR-5 locks
	# highrise_res L5 and data_center L4/L5 one dollar below half-up).
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(BUILDING_ECONOMY_PATH))
	assert_true(data is Dictionary, "data/building_economy.json parses")
	var archetypes: Dictionary = (data as Dictionary)["archetypes"]
	var v: Array = [1.000, 2.150, 5.083, 12.560, 31.629]
	for id in archetypes:
		var row: Dictionary = archetypes[id]
		var cost := float(row["build_cost_l1"])
		var base := float(row["base_tax_l1"])
		for level in range(1, 6):
			assert_true(absf(float(row["base_tax_by_level"][level - 1])
					- CostCurves.round_half_up(base * pow(2.15, level - 1))) <= 1.0,
					"%s base_tax L%d" % [id, level])
			assert_true(absf(float(row["capital_value_by_level"][level - 1])
					- CostCurves.round_half_up(cost * float(v[level - 1]))) <= 1.0,
					"%s capital_value L%d" % [id, level])
		for step in range(1, 5):
			assert_eq(int(row["upgrade_cost_by_step"][step - 1]),
					CostCurves.round_half_up(cost * 1.15 * pow(2.55, step - 1)),
					"%s upgrade step %d" % [id, step])


func test_base_tax_yield_drift_guard() -> void:
	# doc 03 §7 test 7 (RR-5): ±6% drift guard, never an equality. Model values:
	# store and office 4.76%, factory 0.48%, data_center 0.28%, the rest 0.00%.
	var curves := _curves()
	var economy := curves.economy_data()
	var yields: Dictionary = economy["tax"]["TAX_YIELD"]
	var tolerance := float(economy["tax"]["TAX_YIELD_DRIFT_TOLERANCE"])
	assert_almost_eq(tolerance, 0.06)
	var worst := 0.0
	for id in curves.ids():
		if not curves.is_revenue_producing(id):
			continue
		var estimate := float(curves.build_cost_l1(id)) * float(yields[curves.class_of(id)])
		var drift := float(curves.base_tax(id, 1)) / estimate - 1.0
		worst = maxf(worst, absf(drift))
		assert_true(absf(drift) <= tolerance, "%s drift %f" % [id, drift])
	assert_almost_eq(worst, 0.047619, 0.0001, "store/office are the two largest")
	# The negative case RR-18 names: a data_center priced at residential yield.
	var misclassed := 2100.0 / (180000.0 * 0.0100) - 1.0
	assert_almost_eq(misclassed, 0.16667, 0.0001)
	assert_true(misclassed > tolerance, "the guard catches a mis-classed archetype")


# ============================================== §2.3 cost curves (deliverable a)

func test_house_payback_chain() -> void:
	# doc 02 §2.2's worked check, recomputed against doc 03's curves. Re-taken in
	# Wave 17: `UPG_COEFF` 1.45 → 1.15 (doc 93 §Y7) moved both cells, and doc 02
	# §2.6a retired the city's maintenance line on a house, so the net IS the tax.
	var curves := _curves()
	assert_eq(curves.capital_value("house", 3), 6100, "1,200 × 5.083")
	assert_eq(curves.upgrade_cost("house", 2), 3519, "1,200 × 2.9325")
	assert_eq(curves.base_tax("house", 3), 55)
	assert_almost_eq(3519.0 / 55.0, 64.0, 0.2, "doc 02 §2.2: 64.0 gh")


## Doc 93 §Y7's identity, checked on the SHIPPED tables rather than on the closed
## form: `UPG_COEFF = TAX_LEVEL_GROWTH − 1` puts every rung's payback — the
## upgrade's price over the tax it ADDS — inside the ruled [100, 200] gh window,
## and puts the first rung at or below a fresh L1's own 100 gh.
func test_upgrade_payback_sits_inside_the_ruled_window() -> void:
	var curves := _curves()
	for type in ["house", "apartment", "store", "office"]:
		var new_build := float(curves.build_cost_l1(type)) / float(curves.base_tax(type, 1))
		assert_almost_eq(new_build, 100.0, 1.0,
				"%s: a fresh L1 pays back in 100 gh" % type)
		for level in range(1, 6):
			var gain := float(curves.base_tax(type, level + 1)
					- curves.base_tax(type, level))
			if gain <= 0.0:
				continue
			var payback := float(curves.upgrade_cost(type, level)) / gain
			assert_true(payback <= 200.0,
					"%s L%d→L%d payback %.1f gh is outside the ruled window"
							% [type, level, level + 1, payback])
			if level == 1:
				assert_true(payback <= new_build + 1.0,
						"%s: the FIRST rung must not be worse than sprawling "
								% type + "(%.1f gh vs %.1f)" % [payback, new_build])


func test_cost_curve_published_cells() -> void:
	var curves := _curves()
	# doc 03 §2.3's house example, end to end.
	assert_eq(curves.build_cost_l1("house"), 1200)
	var steps: Array[int] = []
	for level in range(1, 5):
		steps.append(curves.upgrade_cost("house", level))
	assert_eq(steps, [1380, 3519, 8973, 22882] as Array[int])
	var capitals: Array[int] = []
	for level in range(1, 6):
		capitals.append(curves.capital_value("house", level))
	assert_eq(capitals, [1200, 2580, 6100, 15072, 37955] as Array[int])
	assert_eq(curves.base_tax("house", 5), 256)
	# doc 02 §2.6's repair example basis.
	assert_eq(curves.capital_value("apartment", 3), 35581)
	# The §2.2 table's L1 and L5 corners.
	assert_eq(curves.base_tax("data_center", 3), 9707)
	assert_eq(curves.base_tax("highrise_com", 5), 8974)
	assert_eq(curves.base_tax("factory", 1), 210)
	assert_eq(curves.base_tax("police_station", 1), 0, "civic buildings earn no tax")
	assert_eq(curves.base_tax("power_plant_gas", 3), 0, "utility buildings earn no tax")


func test_doc02_archetype_aliases_resolve() -> void:
	var curves := _curves()
	assert_eq(curves.resolve_type("high_rise"), "highrise_res")
	assert_eq(curves.base_tax("high_rise", 1), 260)
	assert_eq(curves.resolve_type("power_facility"), "power_plant_gas")
	assert_eq(curves.resolve_type("water_facility"), "water_plant")
	assert_eq(curves.build_cost_l1("water_facility"), 45000)


func test_refunds_and_extras() -> void:
	var curves := _curves()
	# §2.3 demolition refund, §2.13(c) resale, §2.5 PM and contractor.
	assert_eq(curves.demolition_refund_building("house", 5), 9489, "0.25 × 37,955")
	assert_eq(curves.vehicle_resale("mobile_transformer"), 19200, "0.40 × 48,000")
	assert_eq(curves.vehicle_purchase("fire_engine"), 14400)
	assert_eq(curves.vehicle_purchase("fire_engine"),
			CostCurves.round_half_up(1.60 * curves.vehicle_purchase("patrol_car")),
			"C-07 anchor: engine = 1.60 × patrol car")
	assert_eq(curves.pm_cost(curves.capital_value("apartment", 3)), 2135, "0.06 × 35,581")
	assert_true(curves.pm_allowed(0.60))
	assert_false(curves.pm_allowed(0.49), "below 0.50 it is a repair, not a PM")
	assert_eq(curves.contractor_cost(10000), 18000, "1.80 × job cost")
	assert_eq(curves.land_resale(12400), 6820, "0.55 × current price")
	# §2.13(d) road ladder, and the upgrade-coherence check of §7 test 44.
	assert_eq(curves.road_build_cost("STREET"), 1800)
	assert_eq(curves.road_build_cost("AVENUE"), 5200)
	assert_eq(curves.road_demolish_refund("STREET"), 450)
	assert_eq(curves.road_demolish_refund("AVENUE"), 1300)
	assert_true(curves.road_build_cost("STREET") + curves.road_upgrade_cost() > 5200,
			"upgrading is dearer than having built big first (5,800 > 5,200)")
	# §2.13(b) grid ladder.
	assert_eq(curves.capital_value_grid("transformer", 4), 6900)
	assert_eq(curves.capital_value_grid("substation", 1), 15000)
	assert_eq(curves.capital_value_grid("plant_gas", 1), 60000)
	assert_eq(curves.grid_line_cost_per_tile("transmission", 2), 1200)
	assert_eq(curves.grid_line_cost_per_tile("feeder", 1), 110)
	assert_eq(curves.grid_line_cost_per_tile("feeder", 1, true), 286, "underground ×2.6")


# ============================================ §2.2 worked examples A, B and C

func test_tax_worked_example_a() -> void:
	var system := _system()
	var result := system.revenue_for_building(
			{"type": "house", "level": 2, "occ": 1.0, "power": 1.0, "water": 1.0,
			"road": 1.0, "stability": 0.82, "condition": 0.95},
			{"happiness": 68.0, "policy_factor": 1.0, "m_rev": 1.0})
	assert_almost_eq(float(result["f_stability"]), 0.9027, 0.0001)
	assert_almost_eq(float(result["f_happiness"]), 1.040, 0.0001)
	assert_almost_eq(float(result["f_condition"]), 0.9700, 0.0001)  # COND_FLOOR 0.40
	assert_almost_eq(float(result["revenue"]), 23.68, 0.01, "doc 03 example A ⇒ $24/gh")


func test_tax_worked_example_b_outage() -> void:
	var system := _system()
	var healthy := system.revenue_for_building(
			{"type": "house", "level": 2, "occ": 1.0, "power": 1.0, "water": 1.0,
			"road": 1.0, "stability": 0.82, "condition": 0.95},
			{"happiness": 68.0})
	var outage := system.revenue_for_building(
			{"type": "house", "level": 2, "occ": 1.0, "power": 20.0 / 60.0, "water": 0.50,
			"road": 1.0, "stability": 0.61, "condition": 0.95},
			{"happiness": 62.0})
	assert_almost_eq(float(outage["f_power"]), 0.5667, 0.0001)
	assert_almost_eq(float(outage["f_water"]), 0.7250, 0.0001)
	assert_almost_eq(float(outage["f_stability"]), 0.7806, 0.0001)
	assert_almost_eq(float(outage["revenue"]), 8.17, 0.01, "doc 03 example B ⇒ $8/gh")
	var loss := 1.0 - float(outage["revenue"]) / float(healthy["revenue"])
	assert_true(loss >= 0.60, "doc 03 example B loses two thirds of the hour: %f" % loss)


func test_tax_worked_example_c_data_center() -> void:
	var system := _system()
	var result := system.revenue_for_building(
			{"type": "data_center", "level": 3, "occ": 0.95, "power": 1.0, "water": 1.0,
			"road": 1.0, "stability": 0.88, "condition": 1.0},
			{"happiness": 70.0})
	assert_almost_eq(float(result["f_stability"]), 0.9358, 0.0001)
	assert_almost_eq(float(result["revenue"]), 9061.0, 10.0, "doc 03 example C ⇒ $9,061/gh")
	# §2.5: the diesel lifeline runs at a loss while preserving the tax.
	var economy := _curves().economy_data()
	var fuel := 2.21 * float(economy["expenses"]["FUEL_PRICE_PER_MWH"]["diesel"])
	var tariff := 2.21 * float(economy["tariffs"]["POWER_TARIFF_PER_MWH"])
	assert_almost_eq(fuel, 210.0, 0.5)
	assert_almost_eq(tariff, 137.0, 0.5)
	assert_almost_eq(fuel - tariff, 73.0, 0.5, "$73/gh operating loss on backup")


func test_class_floors_applied() -> void:
	# doc 03 §7 test 5: with p = 0, tech earns nothing and residential keeps 35%.
	var system := _system()
	var dark_tech := system.revenue_for_building(
			{"type": "data_center", "level": 1, "power": 0.0}, {"happiness": 60.0})
	assert_almost_eq(float(dark_tech["f_power"]), 0.0)
	assert_almost_eq(float(dark_tech["revenue"]), 0.0)
	var dark_house := system.revenue_for_building(
			{"type": "house", "level": 1, "power": 0.0}, {"happiness": 60.0})
	assert_almost_eq(float(dark_house["f_power"]), 0.35)
	assert_almost_eq(float(system.utility_factor("commercial", "road", 0.0)), 0.55)
	assert_almost_eq(float(system.utility_factor("industrial", "water", 0.0)), 0.20)
	assert_almost_eq(float(system.utility_factor("tech", "road", 0.0)), 0.80)


func test_occupancy_ramp_and_tax_policy() -> void:
	var system := _system()
	assert_almost_eq(system.occupancy_ramp_cap(0.0), 0.35)
	assert_almost_eq(system.occupancy_ramp_cap(36.0), 1.0)
	assert_almost_eq(system.occupancy_ramp_cap(18.0), 0.675)
	assert_almost_eq(system.tax_policy_factor(0.09), 1.0)
	assert_almost_eq(system.tax_policy_factor(0.16), 1.7778, 0.0001, "×1.778 at the top")
	# TAX_RATE_HAPPINESS_COEFF 360 (Wave-7 ruling, doc 92 §20): −(0.16 − 0.09)×360.
	# 0 at TAX_RATE_BASE by construction, which is why the retune moved no anchor.
	assert_almost_eq(system.happiness_tax_delta(0.16), -25.2, 0.001)
	assert_almost_eq(system.happiness_tax_delta(0.09), 0.0, 1e-9)
	assert_almost_eq(system.happiness_tax_delta(0.04), 18.0, 0.001,
			"and a cut is a gift, on the same scale")
	# TAX_RATE_GROWTH_COEFF 8.0 (doc 92 F-5 ruling): the top detent halves growth.
	assert_almost_eq(system.growth_rate_multiplier(0.16), 0.44, 0.001)
	assert_almost_eq(system.growth_rate_multiplier(0.04), 1.40, 0.001)
	assert_false(system.tax_rate_change_allowed(40, 0), "48 gh cooldown")
	assert_true(system.tax_rate_change_allowed(48, 0))


func test_city_revenue_floor() -> void:
	# doc 03 §7 test 6: drive every multiplier down; the city keeps 18% of potential.
	var system := _system()
	var buildings: Array = []
	for i in 10:
		buildings.append({"type": "house", "level": 1, "occ": 1.0, "power": 0.0,
				"water": 0.0, "road": 0.0, "stability": 0.0, "condition": 0.0})
	var snapshot := system.settle_hour({"buildings": buildings, "happiness": 0.0,
			"apply_to_treasury": false})
	var potential := float(snapshot["potential_tax"])
	assert_almost_eq(potential, 120.0, 0.001, "10 × house L1 at full occupancy")
	assert_true(float(snapshot["revenue"]["tax"]) >= 0.18 * potential - 0.001,
			"REV_FLOOR_FRACTION 0.18 holds the aggregate up")
	assert_true(bool(snapshot["revenue_floor_applied"]))
	assert_almost_eq(float(snapshot["foregone"]), potential * 0.82, 0.001)


# ==================================== the $686/gh starter anchor (deliverable b)

func test_starter_gross_base_tax_anchor() -> void:
	# doc 03 §2.12 / C-11: 18×12 + 5×26 + 3×70 + 1×130 = 686, exactly.
	var curves := _curves()
	var total := 0
	for entry in STARTER_MIX:
		total += int(entry[1]) * curves.base_tax(String(entry[0]), 1)
	assert_eq(total, 686, "the pacing model's anchor evaluates exactly")
	var economy := curves.economy_data()
	assert_eq(int(economy["pacing_guardrails"]["STARTER_GROSS_TAX_PER_HOUR"]), 686)


# ================================================ §2.7 land price (deliverable c)

func test_land_price_example_d() -> void:
	var system := _system()
	var inputs := {"d": 2, "dev_terrain": "flat", "risk_index": 0.15,
			"waterfront_edges": 1, "arterial_connections": 2, "prestige": 0.50,
			"elevation_norm": 0.20, "blocks_owned": 9}
	assert_almost_eq(system.land_price_raw(inputs), 12395.4, 1.0,
			"doc 03 prints 12,389 from 4-dp factors; exact chain gives 12,395.40")
	assert_eq(system.land_price(inputs), 12400, "round_to_100 ⇒ $12,400")


func test_land_price_example_e_marsh_block() -> void:
	# doc 03 §7 test 10: block B_0_6 (A7), the cheapest land on the board.
	var system := _system()
	var inputs := {"d": 3, "dev_terrain": "marsh", "risk_index": 0.443,
			"waterfront_edges": 3, "arterial_connections": 0, "prestige": 0.0,
			"elevation_norm": 0.0, "blocks_owned": 9}
	assert_almost_eq(system.land_price_raw(inputs), 6700.87, 0.05)
	assert_eq(system.land_price(inputs), 6700, "$6,700 exactly")
	assert_almost_eq(float(system.land_price(inputs)) / 12400.0, 0.54, 0.005,
			"the marsh block is 54% of the riverfront block's purchase price")


func test_land_escalation_cap() -> void:
	# doc 03 §7 test 12: 200 blocks owned ⇒ escalation exactly 4.0.
	var system := _system()
	assert_almost_eq(system.escalation_factor(9), 1.0)
	assert_almost_eq(system.escalation_factor(19), 1.6)
	assert_almost_eq(system.escalation_factor(200), 4.0)


func test_development_phase_costs_example_f() -> void:
	# doc 03 §2.8 worked example F, both columns, phase by phase.
	var system := _system()
	var riverfront := [1248, 3180, 4770, 6930, 12960, 5500]
	var marsh := [1399, 5232, 12753, 21090, 20916, 7188]
	for index in 6:
		assert_eq(system.development_phase_cost(index, "flat", 2.0, 2), riverfront[index],
				"riverfront phase %d" % index)
		assert_eq(system.development_phase_cost(index, "marsh", 3.0, 0), marsh[index],
				"marsh phase %d" % index)
	assert_eq(system.development_phase_cost("road_install", "marsh", 3.0, 0), 21090,
			"phases resolve by id as well as index")
	assert_eq(system.development_total_cost("flat", 2.0, 2), 34588)
	assert_eq(system.development_total_cost("marsh", 3.0, 0), 68578,
			"half-up: the final phase is 7,187.5 → 7,188")


func test_development_tco_inversion() -> void:
	# doc 03 §7 test 11: all_in(E) ≥ 1.50 × all_in(D); model value 1.602.
	var system := _system()
	var all_in_d := system.land_price({"d": 2, "dev_terrain": "flat", "risk_index": 0.15,
			"waterfront_edges": 1, "arterial_connections": 2, "prestige": 0.50,
			"elevation_norm": 0.20, "blocks_owned": 9}) \
			+ system.development_total_cost("flat", 2.0, 2)
	var all_in_e := system.land_price({"d": 3, "dev_terrain": "marsh", "risk_index": 0.443,
			"waterfront_edges": 3, "arterial_connections": 0, "prestige": 0.0,
			"elevation_norm": 0.0, "blocks_owned": 9}) \
			+ system.development_total_cost("marsh", 3.0, 0)
	assert_eq(all_in_d, 46988)
	assert_eq(all_in_e, 75278)
	assert_almost_eq(float(all_in_e) / float(all_in_d), 1.602, 0.001)
	assert_true(float(all_in_e) >= 1.50 * float(all_in_d))


# ================================== §2.4 E_grid on the starter city (deliverable d)

func test_e_grid_starter_inventory() -> void:
	# doc 03 §7 test 37 / doc 04 test 24: 8.0 MW plant + 6.0 MVA substation +
	# 2.25 MVA of transformers + 1.416 km of line ⇒ $74.3 ± 0.5/gh.
	#
	# **Wave-4 F-4 re-anchor.** Doc 92 F-4 thinned the founding transformer
	# roster from 23 nodes to 18 (`data/starter_city.json`), which is 0.15 MVA of
	# rated plant: `2.40 → 7×0.05 + 10×0.15 + 1×0.40 = 2.25`, and the substation's
	# 6.0 carries the rest, so the inventory total is `8.40 → 8.25`. E_grid is
	# `24 $/MVA-gh` on that plate plus the fuel and line terms, so the line falls
	# by `0.15 × 4.0 = 0.5996/gh`: **74.874 → 74.274**. Nothing else in doc 03's
	# §2.12 chain moved — the line kilometres, the plant and the substation are
	# untouched by the thinning.
	var grid := _starter_power_grid()
	var inventory := grid.grid_inventory()
	var rated := 0.0
	for node in inventory["nodes"]:
		rated += float((node as Dictionary)["rated_mva"])
	var line_km := 0.0
	for line in inventory["lines"]:
		line_km += float((line as Dictionary)["line_km"])
	assert_almost_eq(rated, 8.25, 0.001, "6.0 MVA substation + 2.25 MVA transformers")
	assert_almost_eq(line_km, 1.416, 0.0001, "177 tiles × 8 m")
	var e_grid := _system().e_grid(inventory)
	assert_almost_eq(e_grid, 74.274, 0.5, "40.000 + 24.000 + 9.000 + 1.274")
	var economy := _curves().economy_data()
	assert_almost_eq(e_grid, float(economy["pacing_guardrails"]["STARTER_E_GRID_PER_HOUR"]),
			float(economy["pacing_guardrails"]["STARTER_E_GRID_TEST_TOLERANCE"]))


func test_e_grid_condition_penalty() -> void:
	# ASSET_CONDITION_PENALTY_COEFF 2.0: a half-dead node costs double.
	var system := _system()
	var healthy := system.e_grid({"nodes": [{"rated_mva": 6.0, "condition": 1.0}]})
	var degraded := system.e_grid({"nodes": [{"rated_mva": 6.0, "condition": 0.5}]})
	assert_almost_eq(healthy, 24.0)
	assert_almost_eq(degraded, 48.0)


# ================================= §2.12 the founding ledger (deliverable e)

func test_founding_ledger() -> void:
	var treasury := Treasury.new(_curves().economy_data())
	var system := _system(treasury)
	var snapshot := system.settle_hour(_founding_inputs())
	var revenue: Dictionary = snapshot["revenue"]
	var expenses: Dictionary = snapshot["expenses"]

	assert_almost_eq(float(revenue["tax"]), 740.291412, 0.5, "686 × 0.9722 × 1.110")
	assert_almost_eq(float(revenue["power_tariff"]), 93.0, 0.01)
	assert_almost_eq(float(revenue["water_tariff"]), 3.058, 0.01)
	# RR-78 / RR-79 move this row. `fines` (a held $3.00/gh that stood in for a
	# payout doc 06 was already making) is gone; `city_services` is the live line
	# in its place and settles $0 on a founding hour with no incident in it; and
	# `assistance` is doc 03 §2.5a's founding subsidy at its day-0 full value,
	# `departments` $96 + `fleet` $76 = $172.00/gh.
	assert_almost_eq(float(revenue["city_services"]), 0.0, 1e-9)
	assert_almost_eq(float(revenue["assistance"]), 172.0, 0.01)
	assert_almost_eq(float(revenue["gross"]), 1008.349412, 0.5, "GROSS REVENUE $/gh")

	assert_almost_eq(float(expenses["building_maint"]), 27.44, 0.01, "68,600 × 0.00040")
	assert_almost_eq(float(expenses["departments"]), 96.0, 0.01, "26 + 30 + 20 + 20")
	assert_almost_eq(float(expenses["fleet"]), 58.0, 0.01, "2×7 + 12 + 9 + 9 + 14")
	assert_almost_eq(float(expenses["grid"]), 74.274, 0.5)  # F-4: 2.40 -> 2.25 MVA
	assert_almost_eq(float(expenses["generation_fuel"]), 57.0, 0.01)
	assert_almost_eq(float(expenses["vehicle_fuel"]), 6.0, 0.01)
	assert_almost_eq(float(expenses["water"]), 15.392, 0.01, "0.334 + 1.058 + 14.000")
	assert_almost_eq(float(expenses["roads_repair"]), 185.87, 0.5,
			"150.667 + 35.204 at c_day 0.35")
	assert_almost_eq(float(expenses["debt"]), 0.0)
	assert_almost_eq(float(expenses["total"]), 519.977016, 0.5, "TOTAL EXPENSE $/gh")

	# RR-79 moves this row and only this row's revenue side: +$172.00 of founding
	# assistance, -$3.00 of retired `fines`, so net 319.372396 -> 488.372396 and
	# the game-day figure with it. No expense line moved by a cent.
	assert_almost_eq(float(snapshot["net"]), 488.372396, 0.5, "NET +$488/gh")
	assert_almost_eq(float(snapshot["net"]) * 24.0, 11720.94, 12.0, "+$11,721/game-day")
	assert_eq(treasury.balance, 25000 + 488, "the settled dollar lands in the treasury")
	assert_almost_eq(float(treasury.carry_millidollars) / 1000.0, 0.38, 0.02,
			"and the sub-dollar remainder in the carry")


func test_founding_ledger_matches_published_guardrails() -> void:
	var economy := _curves().economy_data()
	var pacing: Dictionary = economy["pacing_guardrails"]
	var snapshot := _system().settle_hour(_founding_inputs())
	assert_almost_eq(float(snapshot["revenue"]["gross"]),
			float(pacing["STARTER_GROSS_REVENUE_PER_HOUR_EXACT"]), 0.5)
	# NOTE the expense/net pair is deliberately NOT compared here any more.
	# `STARTER_EXPENSE_PER_HOUR_EXACT` / `STARTER_NET_PER_HOUR_EXACT` were promoted
	# to the AS-INTEGRATED anchors by doc 92 §4's ruling, and this fixture is doc 03
	# §2.12's stub-era worked example: it checks the doc's own arithmetic (its
	# literals are asserted in `test_founding_ledger` above), while the live sim is
	# held to the promoted pair by `tests/test_balance_gates.gd` gates 1 and 2.
	assert_true(float(pacing["STARTER_EXPENSE_PER_HOUR_EXACT"])
			< float(snapshot["expenses"]["total"]),
			"the as-integrated ledger bills LESS than doc 03's stub example: "
			+ "E_fuel_vehicle stopped inventing kilometres (doc 92 §4)")
	assert_almost_eq(float(snapshot["expenses"]["roads_repair"]),
			float(pacing["STARTER_ROAD_REPAIR_PER_HOUR"]), 0.5)
	assert_almost_eq(float(snapshot["expenses"]["water"]),
			float(pacing["STARTER_E_WATER_PER_HOUR"]), 0.01)
	assert_almost_eq(float(snapshot["expenses"]["departments"]),
			float(pacing["STARTER_DEPARTMENTS_PER_HOUR"]), 0.01)


func test_road_repair_expectation_and_c_day_floor() -> void:
	# doc 03 §7 test 43 (RR-13): the operating point AND the c_day = 0 floor, so
	# the (1 + 0.75·c_day) coupling is pinned, not just its value at one point.
	var system := _system()
	var tiles := {"tiles": {"AVENUE": 540, "STREET": 243}, "wx_wear_day": 0.0}
	var at_operating_point: Dictionary = tiles.duplicate(true)
	at_operating_point["c_day"] = 0.35
	var at_floor: Dictionary = tiles.duplicate(true)
	at_floor["c_day"] = 0.0
	assert_almost_eq(system.e_roads_repair(at_operating_point), 185.87, 0.5)
	assert_almost_eq(system.e_roads_repair(at_floor), 147.22, 0.5)
	assert_almost_eq(system.e_roads_repair(at_operating_point) / 9.0, 20.65229, 0.01,
			"PACING_ROAD_PER_DEVELOPED_BLOCK")
	# The 1.00-capital-basis figure RR-2 recorded so it is not re-litigated.
	assert_almost_eq(system.e_roads_repair(at_operating_point) / 0.20, 929.35, 2.0)


func test_no_standing_road_upkeep() -> void:
	# doc 03 §7 test 41 / RR-2: the only road money in a settlement is the repair
	# accrual — an empty road inventory books exactly zero.
	var system := _system()
	assert_almost_eq(system.e_roads_repair({}), 0.0)
	var snapshot := system.settle_hour({"roads": {"tiles": {"AVENUE": 540, "STREET": 243},
			"c_day": 0.35}, "apply_to_treasury": false})
	var expenses: Dictionary = snapshot["expenses"]
	assert_false(expenses.has("roads_upkeep"), "no standing per-tile upkeep line exists")
	assert_almost_eq(float(expenses["total"]), 185.87, 0.5,
			"road money in a settlement is repair accrual only")


# ============================ §2.4 / §2.9 which line takes which difficulty knob

## Doc 93 §N1 and §N2, and the reason both rulings exist: **one knob per line,
## never two.** Doc 92 §29.2 measured `E_roads_repair` taking `M_repair × M_exp`
## — 2.0000 on `crisis` against 1.2500 on every other line — which was 48 % of
## the whole difficulty delta on the expense side and the entire sign of the
## founding net. This test is that finding's tripwire, and it is written against
## the LIVE `data/difficulty.json` rows rather than transcribed numbers, so a
## retune of the file moves the expectation with the file and a change of SCOPE
## fails.
##
## The three groups, asserted separately because they are three rulings:
##   * seven recurring lines take `M_exp`;
##   * `roads_repair` takes `M_repair` and NOTHING else;
##   * `debt` takes neither — its difficulty is the APR.
## And on the revenue side, `M_rev` reaches `tax` and no other line (§N2).
func test_one_difficulty_knob_per_ledger_line() -> void:
	var difficulty := Difficulty.load_from_file()
	assert_true(difficulty.is_valid(),
			"difficulty.json errors: " + ", ".join(difficulty.errors))
	var system := _system()
	var by_preset: Dictionary = {}
	for preset in Difficulty.PRESETS:
		var inputs := _founding_inputs()
		inputs["difficulty"] = difficulty.row_of("economic", preset)
		inputs["apply_to_treasury"] = false
		# A non-zero interest bill, so "debt takes neither knob" is an assertion
		# about a number rather than about zero.
		inputs["debt_interest"] = 100.0
		by_preset[preset] = system.settle_hour(inputs)
	var base: Dictionary = by_preset[Difficulty.DEFAULT_PRESET]
	var base_expenses: Dictionary = base["expenses"]
	var base_revenue: Dictionary = base["revenue"]

	var swept_by_m_exp: Array[String] = ["building_maint", "departments", "fleet",
			"vehicle_fuel", "grid", "generation_fuel", "water"]
	for preset in Difficulty.PRESETS:
		var row := difficulty.row_of("economic", preset)
		var m_exp := float(row["M_exp"])
		var m_repair := float(row["M_repair"])
		var m_rev := float(row["M_rev"])
		var expenses: Dictionary = (by_preset[preset] as Dictionary)["expenses"]
		var revenue: Dictionary = (by_preset[preset] as Dictionary)["revenue"]
		for line in swept_by_m_exp:
			assert_almost_eq(float(expenses[line]),
					float(base_expenses[line]) * m_exp, 1e-6,
					"%s on %s is M_exp × standard and nothing else" % [line, preset])
		# The whole point. `M_repair`, NOT `M_repair × M_exp`: the accrual is a
		# repair price, and `repair_cost_road(…, M_repair)` — what the auto-repair
		# policy actually pays for the same tiles — has no `M_exp` in it.
		assert_almost_eq(float(expenses["roads_repair"]),
				float(base_expenses["roads_repair"]) * m_repair, 1e-6,
				"roads_repair on %s takes M_repair alone (doc 93 §N1)" % preset)
		if absf(m_exp - 1.0) > 1e-9:
			assert_true(absf(float(expenses["roads_repair"])
							- float(base_expenses["roads_repair"]) * m_repair * m_exp)
						> 1e-6,
					("roads_repair on %s is M_repair × M_exp again — that is the "
							+ "compounding doc 92 §29.2(b) measured at 2.0000 on crisis")
							% preset)
		assert_almost_eq(float(expenses["debt"]), float(base_expenses["debt"]), 1e-6,
				"debt on %s carries its own difficulty term (the APR)" % preset)
		# §N2: the tax line and only the tax line.
		assert_almost_eq(float(revenue["tax"]), float(base_revenue["tax"]) * m_rev,
				1e-6, "tax on %s is M_rev × standard" % preset)
		for line in ["power_tariff", "water_tariff", "city_services", "assistance"]:
			assert_almost_eq(float(revenue[line]), float(base_revenue[line]), 1e-6,
					"%s on %s is NOT scaled by M_rev — M_rev is the tax multiplier"
							% [line, preset])


# ============================================== §2.5 repair pricing (deliverable f)

func test_repair_pricing_single_source() -> void:
	# doc 03 §7 test 38: one formula, capital_value × damage × 0.85 × M_repair.
	var curves := _curves()
	assert_eq(curves.repair_cost(curves.capital_value_grid("transformer", 4), 0.35), 2053,
			"6,900 × 0.35 × 0.85")
	assert_eq(curves.repair_cost_building("apartment", 3, 0.172), 5202,
			"35,581 × 0.172 × 0.85")
	assert_eq(curves.repair_cost(12 * curves.capital_value_road("STREET"), 0.60), 2203,
			"doc 10 example F repriced: 12 × 360 × 0.60 × 0.85")
	assert_eq(curves.repair_cost_road("STREET", 0.60), 184,
			"per tile the same run rounds to 184 (183.6 half-up), so a 12-tile job is"
			+ " priced once, on the run's capital, not tile by tile")
	assert_eq(curves.repair_cost_road("AVENUE", 1.0), 884, "a fully failed AVENUE tile")
	assert_eq(curves.capital_value_road("STREET"), 360)
	assert_eq(curves.capital_value_road("AVENUE"), 1040)
	# A COLLAPSED tile is a rebuild at full build price, never a repair.
	assert_eq(curves.road_build_cost("AVENUE"), 5200)


func test_repair_difficulty_scalar() -> void:
	var curves := _curves()
	var capital := curves.capital_value("house", 5)
	assert_eq(curves.repair_cost(capital, 1.0, 1.0), 32262, "0.85 × 37,955")
	assert_eq(curves.repair_cost(capital, 1.0, 0.70), 22583, "M_repair casual")
	assert_eq(curves.repair_cost(capital, 1.0, 1.60), 51619, "M_repair crisis")
	assert_eq(curves.repair_cost(capital, 0.0, 1.0), 0)
	assert_eq(curves.repair_cost(capital, 5.0, 1.0), curves.repair_cost(capital, 1.0, 1.0),
			"damage_fraction is clamped to [0,1]")


# ============================================ §2.1 millidollar carry (deliverable g)

func test_no_money_lost_to_rounding() -> void:
	# doc 03 §7 test 14: 1,000 hours of a fractional rate; treasury + carry must
	# equal the exact rational sum within $1.
	var treasury := Treasury.new(_curves().economy_data(), {}, 0)
	var rate := 740.291412
	for hour in 1000:
		treasury.settle(rate, 0.0)
	var exact := rate * 1000.0
	var held := float(treasury.exact_millidollars()) / 1000.0
	assert_true(absf(held - exact) <= 1.0,
			"held %f vs exact %f" % [held, exact])
	assert_true(treasury.carry_millidollars >= 0 and treasury.carry_millidollars < 1000)

	# An exactly representable rate must not drift at all.
	var exact_treasury := Treasury.new(_curves().economy_data(), {}, 0)
	for hour in 1000:
		exact_treasury.settle(0.001, 0.0)
	assert_eq(exact_treasury.balance, 1, "1,000 × $0.001 = exactly $1")
	assert_eq(exact_treasury.carry_millidollars, 0)

	# Negative net floors correctly: no dollar is invented on the way down.
	var negative := Treasury.new(_curves().economy_data(), {}, 100000)
	negative.update_credit_limit(0.0)
	for hour in 1000:
		negative.settle(0.0, 0.6667)
	assert_true(absf(float(negative.exact_millidollars()) / 1000.0
			- (100000.0 - 666.7)) <= 1.0)


# ============================================== §2.11 offline taper (deliverable h)

func test_offline_yield_curve() -> void:
	# doc 03 §7 test 20 with the §2.11 table.
	var system := _system()
	assert_almost_eq(system.offline_effective_hours(5.0), 4.99, 0.05)
	assert_almost_eq(system.offline_effective_hours(20.0), 18.66, 0.05)
	assert_almost_eq(system.offline_effective_hours(60.0), 45.69, 0.20)
	assert_almost_eq(system.offline_effective_hours(240.0), 87.46, 0.20)
	assert_almost_eq(system.offline_effective_hours(480.0), 93.55, 0.20)
	assert_almost_eq(system.offline_effective_hours(720.0), 93.97, 0.10)
	# The multiplier itself: flat for the first 4 gh, then exponential.
	assert_almost_eq(system.offline_yield_mult(0.0), 1.0)
	assert_almost_eq(system.offline_yield_mult(4.0), 1.0)
	assert_almost_eq(system.offline_yield_mult(94.0), exp(-1.0), 0.0001, "h = OFF_FULL + OFF_TAU")
	assert_true(system.offline_yield_mult(200.0) < system.offline_yield_mult(100.0))
	# OFF_TAU is a difficulty knob: casual tapers slower, crisis faster.
	assert_true(system.offline_effective_hours(720.0, 120.0)
			> system.offline_effective_hours(720.0, 60.0))


func test_offline_taper_scales_revenue_and_expenses_identically() -> void:
	# §2.11: a loss-making city is not punished harder for being closed.
	var system := _system()
	var inputs := _founding_inputs()
	inputs["apply_to_treasury"] = false
	var online := system.settle_hour(inputs)
	inputs["yield_mult"] = 0.5
	var offline := system.settle_hour(inputs)
	assert_almost_eq(float(offline["revenue"]["gross"]),
			float(online["revenue"]["gross"]) * 0.5, 0.001)
	assert_almost_eq(float(offline["expenses"]["total"]),
			float(online["expenses"]["total"]) * 0.5, 0.001)
	assert_almost_eq(float(offline["net"]), float(online["net"]) * 0.5, 0.001)


func test_offline_damage_cap() -> void:
	var system := _system()
	assert_eq(system.offline_oneoff_cap(100000, 20000.0, 0.20), 24000)
	assert_eq(system.offline_oneoff_cap(0, 0.0, 0.20), 0)


# ================================ treasury + recovery ladder (deliverable i)

func test_treasury_spend_and_credit_validation() -> void:
	var treasury := Treasury.new(_curves().economy_data(), {}, 25000)
	treasury.update_credit_limit(839.349412 * 24.0)
	assert_eq(treasury.credit_limit, 120866, "max(20,000, 6 × daily gross revenue)")
	var spent := treasury.spend(12400, &"land", "block B_3_1")
	assert_true(bool(spent["ok"]))
	assert_eq(treasury.balance, 12600)
	assert_false(bool(treasury.spend(-5, &"land")["ok"]), "negative spends are rejected")
	assert_false(bool(treasury.credit(-5, &"tax")["ok"]))
	treasury.credit(1000, &"tax", "settlement")
	assert_eq(treasury.balance, 13600)
	assert_eq(int(treasury.lifetime["lifetime_tax"]), 1000)


func test_credit_limit_hard_floor_and_deferred_liability() -> void:
	# doc 03 §7 tests 16 + 17.
	var treasury := Treasury.new(_curves().economy_data(), {}, 0)
	treasury.update_credit_limit(0.0)
	assert_eq(treasury.credit_limit, 20000, "CREDIT_LIMIT_FLOOR")
	var result := treasury.spend(30000, &"repair", "storm")
	assert_eq(treasury.balance, -20000, "clamped at -credit_limit")
	assert_eq(int(result["deferred"]), 10000)
	assert_eq(treasury.deferred_liability, 10000)
	var accrued := _first_event(treasury.drain_events(), &"deferred_liability_accrued")
	assert_almost_eq(float(accrued["condition_penalty_total"]), 0.04,
			0.0001, "10 × $1,000 × 0.004 condition")
	# Deferred debt accrues no interest and is repaid at 35% of positive net.
	treasury.settle(1000.0, 0.0)
	assert_eq(treasury.deferred_liability, 10000 - 350)
	assert_eq(treasury.balance, -20000 + 650)
	# It clears, and says so.
	for hour in 60:
		treasury.settle(1000.0, 0.0)
	assert_eq(treasury.deferred_liability, 0)
	assert_true(_has_event(treasury.drain_events(), &"deferred_liability_cleared"))


func test_austerity_enter_and_exit() -> void:
	# doc 03 §7 test 15.
	var treasury := Treasury.new(_curves().economy_data(), {}, 0)
	treasury.update_credit_limit(0.0)
	var daily_expense := 520.576566 * 24.0
	assert_false(treasury.update_austerity(daily_expense, 0))
	treasury.spend(5000, &"repair", "cascade")
	assert_true(treasury.update_austerity(daily_expense, 10), "auto-enters below zero")
	assert_true(_has_event(treasury.drain_events(), &"austerity_entered"))
	assert_almost_eq(treasury.austerity_expense_mult(), 0.55)
	assert_false(bool(treasury.spend(1200, &"construction")["ok"]),
			"new construction is blocked in austerity")
	assert_false(bool(treasury.spend(9000, &"vehicle")["ok"]))
	assert_true(bool(treasury.spend(100, &"repair")["ok"]),
			"in-flight work and repairs continue")
	treasury.credit(12000, &"tax")
	assert_false(treasury.update_austerity(daily_expense, 20),
			"exits at 0.5 × daily gross expense")
	assert_true(_has_event(treasury.drain_events(), &"austerity_exited"))
	assert_almost_eq(treasury.austerity_expense_mult(), 1.0)


func test_austerity_scales_recurring_expenses() -> void:
	var treasury := Treasury.new(_curves().economy_data(), {}, 0)
	treasury.update_credit_limit(0.0)
	treasury.spend(1000, &"repair")
	treasury.update_austerity(1000.0, 0)
	var inputs := _founding_inputs()
	inputs["apply_to_treasury"] = false
	var austere := EconomySystem.new(_curves(), treasury).settle_hour(inputs)
	var normal := _system().settle_hour(inputs)
	assert_almost_eq(float(austere["expenses"]["grid"]),
			float(normal["expenses"]["grid"]) * 0.55, 0.001)
	assert_almost_eq(float(austere["revenue"]["gross"]), float(normal["revenue"]["gross"]),
			0.001, "austerity is an expense lever, not a revenue one")


func test_debt_interest_and_relief_grant_gates() -> void:
	# doc 03 §7 test 18 — all four conditions, the cooldown, and crisis.
	var economy := _curves().economy_data()
	var treasury := Treasury.new(economy, {}, 0)
	treasury.update_credit_limit(0.0)
	treasury.spend(20000, &"repair")
	assert_eq(treasury.balance, -20000)
	assert_eq(treasury.debt_interest_per_hour(), 7, "20,000 × 0.008 / 24")
	var daily_revenue := 839.349412 * 24.0
	assert_eq(treasury.maybe_grant_relief(0, daily_revenue, 5.0), 0,
			"positive trailing net blocks the grant")
	var grant := treasury.maybe_grant_relief(0, daily_revenue, -10.0)
	assert_eq(grant, 30217, "clamp(1.5 × daily gross revenue, 8,000, 250,000)")
	assert_true(_has_event(treasury.drain_events(), &"relief_grant_awarded"))
	treasury.spend(40000, &"repair")
	assert_eq(treasury.maybe_grant_relief(60, daily_revenue, -10.0), 0,
			"never twice inside RELIEF_COOLDOWN_HOURS 120")
	assert_true(treasury.maybe_grant_relief(120, daily_revenue, -10.0) > 0)
	# Crisis has no safety net at all.
	var crisis := Treasury.new(economy, {"relief_grants_per_era": 0,
			"CREDIT_APR_PER_GAME_DAY": 0.022}, 0)
	crisis.update_credit_limit(0.0)
	crisis.spend(20000, &"repair")
	assert_eq(crisis.maybe_grant_relief(0, daily_revenue, -10.0), 0,
			"crisis difficulty has zero grants")
	assert_eq(crisis.debt_interest_per_hour(), 18, "20,000 × 0.022 / 24")


func test_mothball_and_station_upkeep_curve() -> void:
	var system := _system()
	assert_almost_eq(system.station_upkeep("police_station", 1), 26.0)
	assert_almost_eq(system.station_upkeep("police_station", 2), 46.0, 0.001,
			"26 × 1.75, half-up")
	assert_almost_eq(system.station_upkeep("fire_station", 3), 92.0, 0.001, "30 × 1.75²")
	assert_almost_eq(system.station_upkeep("water_works", 1, true), 3.0, 0.001,
			"a mothballed station pays 15%")
	assert_true(system.station_upkeep_is_staffing_only("water_works"),
			"RR-16: E_water bills the pump O&M, this line buys operators")
	assert_false(system.station_upkeep_is_staffing_only("police_station"))
	assert_almost_eq(system.station_upkeep("power_plant_gas", 1), 0.0, 0.0001,
			"plants and substations carry no department line at all (C-08)")
	assert_eq(system.mothball_reactivation_cost("police_station"), 374, "0.60 × upkeep × 24")


func test_treasury_save_roundtrip() -> void:
	# doc 03 §7 test 25 + §3.3's section shape. JSON round-trips through floats,
	# which is exactly what the SaveSection contract warns about.
	var treasury := Treasury.new(_curves().economy_data(), {}, 972787)
	treasury.carry_millidollars = 412
	treasury.deferred_liability = 4200
	treasury.update_credit_limit(100800.0)
	treasury.spend(1000000, &"construction")
	treasury.update_austerity(1000.0, 51200)
	treasury.maybe_grant_relief(51200, 100800.0, -5.0)
	treasury.lifetime["lifetime_tax"] = 41822190
	var serialized := treasury.serialize()
	assert_true(serialized.has("revenue_carry_millidollars"))
	assert_false(serialized.has("absence_hours_elapsed"), "deleted by C-20")
	assert_false(serialized.has("schema_version"), "sections carry section_version (C-25)")
	var text := JSON.stringify(serialized)
	var reloaded: Dictionary = JSON.parse_string(text)
	var restored := Treasury.new(_curves().economy_data(), {}, 0)
	restored.deserialize(reloaded)
	assert_eq(restored.balance, treasury.balance)
	assert_eq(restored.carry_millidollars, treasury.carry_millidollars)
	assert_eq(restored.deferred_liability, treasury.deferred_liability)
	assert_eq(restored.credit_limit, treasury.credit_limit)
	assert_eq(restored.austerity_active, treasury.austerity_active)
	assert_eq(restored.austerity_entered_hour, treasury.austerity_entered_hour)
	assert_eq(restored.relief_grants_used, treasury.relief_grants_used)
	assert_eq(restored.relief_last_grant_hour, treasury.relief_last_grant_hour)
	assert_eq(int(restored.lifetime["lifetime_tax"]), 41822190)
	assert_eq(restored.serialize(), serialized, "deep-equal round trip")


func test_settlement_is_deterministic_and_offline_uses_one_code_path() -> void:
	# doc 03 §7 tests 21 + 24: the same inputs settle to the same treasury twice,
	# and offline with yield_mult 1.0 is byte-identical to online.
	var first := Treasury.new(_curves().economy_data(), {}, 25000)
	var second := Treasury.new(_curves().economy_data(), {}, 25000)
	var system_a := EconomySystem.new(_curves(), first)
	var system_b := EconomySystem.new(_curves(), second)
	for hour in 100:
		var online := _founding_inputs()
		online["hour"] = hour
		system_a.settle_hour(online)
		var offline := _founding_inputs()
		offline["hour"] = hour
		offline["yield_mult"] = 1.0
		system_b.settle_hour(offline)
	assert_eq(first.balance, second.balance)
	assert_eq(first.carry_millidollars, second.carry_millidollars)
	# 100 × $488.372396 = $48,837 (was $31,937 before RR-79's founding assistance
	# joined the revenue side, and $31,878 before doc 92 F-4 took 0.15 MVA of
	# transformer plate out of `E_grid`).
	assert_true(absi(first.balance - (25000 + 48837)) <= 3,
			"100 gh of the founding ledger, got %d" % first.balance)


# ------------------------------------------------------------------ fixtures

## doc 03 §2.12's founding ledger inputs, each line sourced from the owning doc.
func _founding_inputs() -> Dictionary:
	var buildings: Array = []
	for entry in STARTER_MIX:
		for i in int(entry[1]):
			buildings.append({"type": String(entry[0]), "level": 1, "occ": 1.0,
					"power": 1.0, "water": 1.0, "road": 1.0,
					"stability": STARTER_STABILITY, "condition": 1.0})
	return {
		"hour": 0,
		"buildings": buildings,
		"happiness": STARTER_HAPPINESS,
		"tax_rate": 0.09,
		"stations": [
			{"type": "police_station", "level": 1},
			{"type": "fire_station", "level": 1},
			{"type": "water_works", "level": 1},
			{"type": "construction_yard", "level": 1},
		],
		# doc 09's starter roster; km are chosen to price to the $6/gh doc 03
		# holds pending doc 06's `vehicle_km_this_hour` (§9 item 6b).
		"vehicles": [
			{"type": "patrol_car", "km_this_hour": 1.0},
			{"type": "patrol_car", "km_this_hour": 1.0},
			{"type": "fire_engine", "km_this_hour": 1.5 / 1.9},
			{"type": "utility_service_truck", "km_this_hour": 1.0},
			{"type": "water_repair_truck", "km_this_hour": 1.0},
			{"type": "construction_crew", "km_this_hour": 1.0},
		],
		"grid_inventory": _starter_power_grid().grid_inventory(),
		# The held pair (§9 item 6b): both sides of ~1.5 MWh/gh delivered.
		"delivered_mwh": 1.5,
		"generation": [{"plant_type": "gas", "mwh": 1.5, "level": 1}],
		"water": {"m3_treated": 5.56, "main_km": 1.512, "main_condition": 1.0,
				"pump_capacity_m3h": 40.0, "delivered_m3": 5.56},
		"roads": {"tiles": {"AVENUE": 540, "STREET": 243}, "c_day": 0.35, "wx_wear_day": 0.0},
		# RR-78: no incident resolved in this synthetic hour, so the live
		# `city_services` line is 0 — where the retired `fines` line printed a
		# held $3.00/gh whether anything happened or not.
		"city_services": {"dispatch": 0, "street": 0},
		# RR-79: the founding hour is game-day 0, so the assistance taper is at
		# its full published value.
		"founding_assistance": 172.0,
	}


## doc 09 §2.9.5's starter electrical plant, read out of `data/starter_city.json`
## and rebuilt through the real `PowerGrid` so `E_grid` consumes the real
## `grid_inventory()` contract (doc 03 §5, report 98 C-12).
func _starter_power_grid() -> PowerGrid:
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(STARTER_CITY_PATH))
	var grid := PowerGrid.new()
	if not (parsed is Dictionary):
		_fail("cannot parse " + STARTER_CITY_PATH)
		return grid
	var power: Dictionary = (parsed as Dictionary).get("power", {})
	for entry in power.get("nodes", []):
		var node: Dictionary = entry
		grid.add_component(String(node["id"]), StringName(String(node["kind"])),
				{"level": int(node.get("level", 1)),
				"condition": float(node.get("condition", 1.0))})
	for entry in power.get("lines", []):
		var line: Dictionary = entry
		var route: Array = []
		for tile in int(line.get("length_tiles", 0)):
			route.append(Vector2i(tile, 0))
		grid.add_component(String(line["id"]), StringName(String(line["kind"])),
				{"conductor_class": int(line.get("class", 1)), "route": route,
				"condition": float(line.get("condition", 1.0))})
	return grid


func _first_event(drained: Array, type: StringName) -> Dictionary:
	for entry in drained:
		var event: Dictionary = entry
		if event.get("type", &"") == type:
			return event
	return {}


func _has_event(drained: Array, type: StringName) -> bool:
	return not _first_event(drained, type).is_empty()


## Doc 03 §2.5a / doc 93 §Y4 — the taper's WINDOW, published because the taper
## itself is correct and its silence was the defect. PA-32 measured it as the
## largest single mover of the net chip in the opening fortnight with no toast,
## no log row and no end date anywhere. No dollar moves for this test to check:
## it checks that the number the surface needs exists and agrees with the
## per-hour curve it is derived from.
func test_founding_assistance_window_is_published() -> void:
	var curves := _curves()
	var grants: Dictionary = curves.economy_data()["grants"]
	var days := int(grants["FOUNDING_ASSISTANCE_DAYS"])
	var per_hour := float(grants["FOUNDING_ASSISTANCE_PER_HOUR"])
	assert_eq(curves.founding_assistance_days_left(0), days,
			"on the founding day the whole window is still to come")
	for day in range(0, days + 3):
		var left := curves.founding_assistance_days_left(day)
		assert_eq(left, maxi(0, days - day), "day %d" % day)
		# The two readings of the same pair must agree about the END: the hourly
		# curve pays nothing exactly when the window says nothing is left.
		assert_eq(left == 0, is_zero_approx(curves.founding_assistance_per_hour(day)),
				"day %d: days_left and the hourly curve disagree about the end" % day)
	# And the step is the one PA-32 measured: 172/7 = $24.571/gh = $589.71 a day.
	assert_almost_eq(per_hour / float(days), 24.5714, 0.001)
	assert_almost_eq(24.0 * per_hour / float(days), 589.714, 0.01)


## …and the settle snapshot carries it, at the TOP and not inside `revenue`,
## because every key in `revenue` is a dollar a budget sheet sums and this is a
## count (doc 93 §Y4).
func test_settlement_carries_the_assistance_window_as_a_count() -> void:
	var system := _system()
	var inputs := _founding_inputs()
	inputs["founding_assistance_days_left"] = 4
	var snapshot := system.settle_hour(inputs)
	assert_eq(int(snapshot["assistance_days_left"]), 4)
	assert_false((snapshot["revenue"] as Dictionary).has("assistance_days_left"),
			"a count must not sit among the dollar rows a sheet totals")

