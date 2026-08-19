extends SimTest
## Doc 05 §3.1 / §8 and the report-98 guards: tests 1, 24, 26 and 30's data half.
## These fail loudly if a ruling is silently reverted in `data/water.json`.

const K_DEM := 2.45


func _data() -> WaterData:
	return WaterData.from_dict(StarterCityLoader.read_json("res://data/water.json"))


# --- test 1: no local curves (C-33) ---------------------------------------

func test_no_local_curves() -> void:
	var data := _data()
	assert_true(data.is_valid(), "water.json validates: %s" % str(data.errors))
	var raw := StarterCityLoader.read_json("res://data/water.json")
	assert_false(JSON.stringify(raw).contains("_hourly"),
			"C-33: no *_hourly key may live in data/water.json")
	assert_true(_max_numeric_array_len(raw) < 24,
			"C-33: no 24-entry array — doc 01's data/time.json owns both curves")


func test_demand_split_rows_sum_to_one() -> void:
	var data := _data()
	for archetype in data.demand_split:
		var row: Dictionary = data.demand_split[archetype]
		assert_almost_eq(float(row["res"]) + float(row["com"]) + float(row["proc"]),
				1.000, 0.001, "demand_split[%s]" % archetype)
	# Spot-check the audit-trail rows §2.4 derives cell by cell.
	assert_almost_eq(float(data.split_for("house")["res"]), 1.00, 0.0001)
	assert_almost_eq(float(data.split_for("data_center")["proc"]), 0.97, 0.0001)
	assert_almost_eq(float(data.split_for("apartment")["res"]), 0.88, 0.0001)
	assert_almost_eq(float(data.split_for("office")["com"]), 0.73, 0.0001)


func test_channels_live_in_time_json_not_here() -> void:
	var time_data := StarterCityLoader.read_json("res://data/time.json")
	var curves: Dictionary = time_data.get("curves", {})
	assert_true(curves.has("water_demand_residential"), "doc 01 owns the residential channel")
	assert_true(curves.has("water_demand_commercial"), "doc 01 owns the commercial channel")
	var set := DayCurveSet.new()
	assert_true(set.load_from(time_data), "time.json loads: %s" % str(set.errors))
	# §2.14 states these as reproducible inputs: res 1.075 @ h13, 1.333 @ h19,
	# 1.025 @ h22; com 1.65 @ h13, 1.00 @ h19, 0.45 @ h22.
	assert_almost_eq(set.channel_curve_value("water_demand_residential", 13.0), 1.075, 0.001)
	assert_almost_eq(set.channel_curve_value("water_demand_residential", 19.0), 1.3333, 0.001)
	assert_almost_eq(set.channel_curve_value("water_demand_residential", 22.0), 1.025, 0.001)
	assert_almost_eq(set.channel_curve_value("water_demand_commercial", 13.0), 1.65, 0.001)
	assert_almost_eq(set.channel_curve_value("water_demand_commercial", 19.0), 1.00, 0.001)
	# FINDING: doc 05 §2.14 quotes `water_demand_commercial = 0.45 at h22`, but
	# doc 01's authored keyframes ([21, 0.65], [23, 0.35]) interpolate to 0.50.
	# `data/time.json` is the store (C-33), so the sim reads 0.50 and the worked
	# examples that quote 0.45 are driven from injected channels in the water
	# tests. Raised for the overseer — a doc 05 §2.14 quote, not a doc 01 bug.
	assert_almost_eq(set.channel_curve_value("water_demand_commercial", 22.0), 0.50, 0.001)


# --- test 24: the variant tables (C-34 / C-35) -----------------------------

func test_variant_tables() -> void:
	var data := _data()
	for key in ["source_river", "source_well", "treatment", "pump", "tank", "booster"]:
		assert_eq((data.components[key] as Dictionary).size(), 5,
				"%s must carry exactly 5 levels" % key)
	# `components.pump.base_kw` IS doc 02's water_facility kW column.
	var expected_kw := [60.0, 145.0, 360.0, 880.0, 2160.0]
	for level in range(1, 6):
		assert_almost_eq(float(data.component(&"pump", level)["base_kw"]),
				expected_kw[level - 1], 0.0001, "pump L%d base_kw" % level)
	# rated_flow[L] == round_wu(40.0 × 2.45^(L−1)), doc 02's standard-class shape.
	var expected_flow := [40.0, 98.0, 240.0, 588.0, 1441.0]
	for level in range(1, 6):
		var generated: float = 40.0 * pow(K_DEM, level - 1)
		assert_almost_eq(float(data.component(&"pump", level)["rated_flow_m3h"]),
				expected_flow[level - 1], 0.0001, "pump L%d rated flow" % level)
		assert_true(absf(generated - expected_flow[level - 1]) / expected_flow[level - 1] < 0.005,
				"L%d flow is within doc 02's rounding of 40 × 2.45^(L-1)" % level)
	# `base_kw = kw_per_m3h[variant] × capacity` reproduces the column (§2.6).
	var kw_per: Dictionary = data.global_values["kw_per_m3h"]
	assert_almost_eq(float(kw_per["pump"]) * 40.0, 60.0, 0.0001)
	assert_almost_eq(float(kw_per["treatment"]) * 80.0, 40.0, 0.0001,
			"treatment L1: 0.50 × 80.0 = 40")
	assert_almost_eq(float(kw_per["source_river"]) * 107.0, 32.1, 0.0001,
			"river intake L1: 0.30 × 107 → 32")
	assert_almost_eq(float(data.component(&"source", 1, "river")["base_kw"]), 32.0, 0.0001)
	assert_almost_eq(float(data.component(&"tank", 1)["base_kw"]), 5.0, 0.0001,
			"C-35: the gravity tank draws telemetry load, not doc 02's flat 60 kW")


func test_l1_facility_serves_two_thousand_residents() -> void:
	var data := _data()
	# §2.4's C-34 anchor, verified BOTH ways.
	var per_capita := data.global_value("res_per_capita_m3h_reference", 0.020)
	assert_almost_eq(40.0 / per_capita, 2000.0, 0.001, "one L1 pump = 2,000 residents")
	assert_almost_eq(40.0 / 0.08, 500.0, 0.001, "…and 500 L1 houses × 4 = 2,000")


func test_backup_coverage_table() -> void:
	var data := _data()
	# C-36: this doc owns coverage_frac; doc 04 owns the fuel.
	assert_almost_eq(data.coverage_frac_for(1), 0.00, 0.0001, "no module below L2")
	assert_almost_eq(data.coverage_frac_for(2), 0.60, 0.0001)
	assert_almost_eq(data.coverage_frac_for(3), 0.70, 0.0001)
	assert_almost_eq(data.coverage_frac_for(4), 0.85, 0.0001)
	assert_almost_eq(data.coverage_frac_for(5), 1.00, 0.0001)
	# backup_kw = round_kw(coverage_frac × base_kw): 0.60 × 145 = 87 (example D).
	assert_almost_eq(data.backup_kw_for(&"pump", 2), 87.0, 0.0001)
	assert_almost_eq(data.backup_kw_for(&"pump", 5), 2160.0, 0.0001,
			"L5 is fully backed, so backup_kw == base_kw")
	assert_almost_eq(data.kw_required(&"pump", 2), 145.0, 0.0001)


func test_mains_ladder() -> void:
	var data := _data()
	assert_almost_eq(data.main_capacity("service"), 53.5, 0.0001)
	assert_almost_eq(data.main_capacity("trunk"), 213.0, 0.0001)
	assert_almost_eq(data.main_capacity("arterial"), 640.0, 0.0001)
	assert_almost_eq(data.global_value("fire_flow_per_engine_m3h"), 8.0, 0.0001,
			"C-34 rescale: 60 × 0.1333 = 7.998 → 8.0")


# --- test 26: no currency, no curves, no coverage radius (C-07/C-16/C-06) ---

func test_no_currency_and_no_coverage_radius() -> void:
	var data := _data()
	assert_true(data.is_valid(), "the loader's own C-07 guard passes: %s" % str(data.errors))
	# Key names only: the `_note` blocks legitimately NAME the deleted keys to
	# point a reader at doc 03 / doc 04, which is the whole point of §8's table.
	var keys := _all_keys(StarterCityLoader.read_json("res://data/water.json"))
	for token: String in ["build_cost", "maintenance_per_hour", "cost_per_tile", "base_cost",
			"chem_cost", "fuel_l_per_kwh", "fuel_price", "fuel_capacity",
			"backup_start_minutes", "overhaul_cost_frac", "pressure_radius",
			"residential_hourly", "commercial_hourly", "weather_demand_mult",
			"idle_demand_frac", "process_demand_m3h"]:
		assert_false(keys.has(token), "deleted key %s must not return" % token)
	# The four surviving ratio keys are dimensionless, and stay that way.
	var ratios: Dictionary = data.price_inputs["variant_cost_ratio_l1"]
	for key in ratios:
		assert_true(float(ratios[key]) <= WaterData.RATIO_KEY_MAX,
				"%s must be a ratio, not a price" % key)
	assert_almost_eq(float(data.price_inputs["flush_cost_frac_of_capital"]), 0.125, 0.0001)


func test_currency_guard_actually_fires() -> void:
	# The guard is only worth having if a reverted price fails the load.
	var raw := StarterCityLoader.read_json("res://data/water.json")
	raw["price_inputs"]["build_cost"] = 45000
	var data := WaterData.from_dict(raw)
	assert_false(data.is_valid(), "C-07: a dollar magnitude must fail the loader")


func test_hourly_curve_guard_actually_fires() -> void:
	var raw := StarterCityLoader.read_json("res://data/water.json")
	var curve: Array = []
	for i in 24:
		curve.append(1.0)
	raw["demand_split"]["residential_hourly"] = curve
	var data := WaterData.from_dict(raw)
	assert_false(data.is_valid(), "C-33: a re-added 24-entry curve must fail the loader")


func test_kw_column_guard_actually_fires() -> void:
	var raw := StarterCityLoader.read_json("res://data/water.json")
	raw["components"]["pump"][0][2] = 61
	var data := WaterData.from_dict(raw)
	assert_false(data.is_valid(), "C-34: pump kW must equal doc 02's column exactly")


# --- RR-11: `_provenance` is documentation, never a sim input --------------

func test_provenance_is_never_a_sim_input() -> void:
	var data := _data()
	var reference: Dictionary = data.provenance["_starter_reference"]
	assert_almost_eq(float(reference["starter_demand_m3h_mean"]), 5.56, 0.001)
	assert_almost_eq(float(reference["starter_supply_m3h"]), 40.0, 0.001)
	assert_almost_eq(float(reference["starter_headroom_x"]), 7.2, 0.05)
	assert_almost_eq(40.0 / 5.56, 7.194, 0.001, "RR-11: 7.2×, not the withdrawn 4.9×")
	# It must not have leaked into any runtime table.
	for key in data.global_values:
		assert_false(String(key).contains("starter"),
				"RR-11: no _starter_reference key may bind to a runtime field")
	assert_false(data.effects.has("starter_demand_m3h_mean"))


func _all_keys(value: Variant, into: Dictionary = {}) -> Dictionary:
	match typeof(value):
		TYPE_DICTIONARY:
			for key in value:
				into[String(key)] = true
				_all_keys(value[key], into)
		TYPE_ARRAY:
			for entry in value:
				_all_keys(entry, into)
		_:
			pass
	return into


func _max_numeric_array_len(value: Variant) -> int:
	match typeof(value):
		TYPE_ARRAY:
			var longest := 0
			var array: Array = value
			var numeric := true
			for entry in array:
				if typeof(entry) != TYPE_INT and typeof(entry) != TYPE_FLOAT:
					numeric = false
				longest = maxi(longest, _max_numeric_array_len(entry))
			return maxi(longest, array.size() if numeric else 0)
		TYPE_DICTIONARY:
			var longest := 0
			for key in value:
				longest = maxi(longest, _max_numeric_array_len(value[key]))
			return longest
		_:
			return 0
