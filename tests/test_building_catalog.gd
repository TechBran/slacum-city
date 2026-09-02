extends SimTest
## Doc 02 §7 data-integrity suite for `data/buildings.json` + `data/building_rules.json`
## and `sim/buildings/building_catalog.gd`.
##
## Covers test 1 (`test_catalog_loads`), test 2 (`test_curve_consistency` — the
## diff test), test 2b (`test_water_seeds_published`), test 3
## (`test_no_deleted_columns`), test 4 (`test_demand_growth_invariant`),
## test 6 (`test_water_anchor`) and the `water_facility` half of test 6b.
##
## The diff test regenerates cells from `building_rules.json`'s NORMATIVE
## `seed_rows` (report 98 RR-8 — never from a printed or stored L1 cell) using
## exact scaled-integer arithmetic, so a `.5` tie is a real tie and not a
## binary-float artefact. Doc 02's rounding is half-up at every tie.

const BUILDINGS_PATH := "res://data/buildings.json"
const RULES_PATH := "res://data/building_rules.json"

const ARCHETYPES := [
	"house", "apartment", "store", "office", "high_rise", "data_center",
	"police_station", "fire_station", "power_facility", "substation",
	"water_facility", "construction_yard",
]

## Decimal places each seed field is authored at in doc 02 §8 `seed_rows`.
const SEED_DIGITS := {
	"pop": 0, "jobs": 0, "power_kw": 0, "water": 3, "time_h": 0,
	"decay": 5, "fire_p": 5, "fire_load": 0, "crime": 1, "coverage_radius": 0,
}
const K_DIGITS := 2  # every multiplier in §2.2 is authored at 2 dp
const UPGRADE_FACTOR_DIGITS := 2
const BUILD_TIME_DIGITS := 1  # build_time cells are multiples of 0.5
## Core Design Rule 5, as amended by doc 92 §24: five rungs for every
## archetype, six for the growth stock. `LEVEL_COUNT` is the FLOOR;
## `_levels_of()` is the height of one archetype's own ladder.
const LEVEL_COUNT := 5
const TOP_LEVEL_COUNT := 6
const SIXTH_LEVEL_ARCHETYPES := [
	"house", "apartment", "store", "office", "high_rise", "data_center",
]
const COVERAGE_DIGITS := 2  # the ladder and the archetype multiplier are both 2 dp

## Report 98 RR-19: doc 02 published four cells that violated its own §2.2
## rules; the ruling made the rules canonical and CORRECTED the four cells.
## There is no whitelist — the diff test below regenerates every cell with no
## exceptions. What is pinned here is the correction: each cell must equal the
## rule-generated value and must NOT have drifted back to what doc 02 used to
## print. `water_facility` L2 jobs was found by this suite's own sweep (doc 97
## §1 never audited the k_out column).
const RR19_CORRECTIONS := [
	{
		"archetype": "house", "level": 4, "field": "fire_ignition_per_hour",
		"was": 0.00032, "now": 0.00031,
		"arithmetic": "0.00015 x 1.28^3 = 0.000314573 -> 5 dp half-up = 0.00031",
	},
	{
		"archetype": "construction_yard", "level": 3, "field": "fire_ignition_per_hour",
		"was": 0.00065, "now": 0.00066,
		"arithmetic": "0.00040 x 1.28^2 = 0.00065536 -> 5 dp half-up = 0.00066",
	},
	{
		"archetype": "fire_station", "level": 2, "field": "coverage_radius_tiles",
		"was": 22.0, "now": 23.0,
		"arithmetic": "18 x 1.25 = 22.5 exact tie -> half-up = 23",
	},
	{
		"archetype": "water_facility", "level": 2, "field": "jobs",
		"was": 18.0, "now": 19.0,
		"arithmetic": "10 x 1.85 = 18.5 exact tie -> half-up = 19",
	},
]

## Doc 02 §7 test 3 — deleted by report 98, must never reappear.
const DELETED_COLUMNS := [
	"build_cost", "upgrade_cost", "tax_cents_per_hour", "upkeep_cents_per_hour",
	"power_supply_kw", "power_throughput_kw", "feeder_radius_tiles",
	"water_supply_wu_per_hour", "pressure_radius_tiles", "unit_slots", "crew_slots",
	"burn_hours", "condition_loss_per_hour", "required_fire_units", "spread_radius_tiles",
]

const CURVE_COLUMNS := [
	"population", "jobs", "power_demand_kw", "water_demand", "build_time_hours",
	"upgrade_time_hours", "decay_per_hour", "fire_ignition_per_hour", "fire_load",
	"crime_weight", "req_fire_coverage", "req_police_coverage", "min_city_level",
	"coverage_radius_tiles",
]

const EPS := 1e-9

var _cached_buildings_text := ""
var _cached_rules_text := ""


# --------------------------------------------------------------------------
# Fixtures
# --------------------------------------------------------------------------

func _buildings_data() -> Dictionary:
	if _cached_buildings_text.is_empty():
		_cached_buildings_text = FileAccess.get_file_as_string(BUILDINGS_PATH)
	return JSON.parse_string(_cached_buildings_text)


func _rules_data() -> Dictionary:
	if _cached_rules_text.is_empty():
		_cached_rules_text = FileAccess.get_file_as_string(RULES_PATH)
	return JSON.parse_string(_cached_rules_text)


func _catalog() -> BuildingCatalog:
	var catalog := BuildingCatalog.new(_buildings_data(), _rules_data())
	assert_true(catalog.is_valid(),
			"shipped data must validate: " + ", ".join(catalog.errors))
	return catalog


# --------------------------------------------------------------------------
# Exact scaled-integer decimal helpers (half-up, no binary-float ties)
# --------------------------------------------------------------------------

## The height of one archetype's own ladder (doc 02 §2.14).
static func _levels_of(archetype: String) -> int:
	return TOP_LEVEL_COUNT if SIXTH_LEVEL_ARCHETYPES.has(archetype) else LEVEL_COUNT


static func _ipow(base: int, exponent: int) -> int:
	var result := 1
	for _i in exponent:
		result *= base
	return result


## Authored decimal -> exact integer numerator at `digits` decimal places.
func _scaled(value: float, digits: int) -> int:
	var factor := float(_ipow(10, digits))
	var numerator := int(round(value * factor))
	assert_true(absf(value * factor - float(numerator)) < 1e-6,
			"seed %f is not representable at %d dp" % [value, digits])
	return numerator


## A rounding step (0.5, 5, 0.000001, …) as [numerator, decimal_digits].
func _step_parts(step: float) -> Array:
	for digits in 9:
		var factor := float(_ipow(10, digits))
		var numerator := int(round(step * factor))
		if absf(step * factor - float(numerator)) < 1e-9:
			return [numerator, digits]
	_fail("cannot express rounding step %f as a decimal" % step)
	return [1, 0]


## Round `num / 10^digits` to the nearest multiple of the step, HALF-UP.
func _round_step(num: int, digits: int, step: Array) -> float:
	var step_num: int = step[0]
	var step_digits: int = step[1]
	var numerator := num * _ipow(10, step_digits)
	var denominator := _ipow(10, digits) * step_num
	var quotient := (2 * numerator + denominator) / (2 * denominator)
	return float(quotient * step_num) / float(_ipow(10, step_digits))


## Pick the first `[bound, step]` rung of a §8 ladder the magnitude falls under.
func _ladder_step(num: int, digits: int, ladder: Array) -> Array:
	for rung in ladder:
		if rung[0] == null:
			return _step_parts(float(rung[1]))
		if num < int(rung[0]) * _ipow(10, digits):
			return _step_parts(float(rung[1]))
	_fail("rounding ladder has no tail entry")
	return [1, 0]


## round_rule(seed x k^(L-1)) on a §8 ladder.
func _curve_ladder(seed: float, seed_field: String, k: float, level: int, ladder: Array) -> float:
	var digits: int = int(SEED_DIGITS[seed_field]) + K_DIGITS * (level - 1)
	var num := _scaled(seed, int(SEED_DIGITS[seed_field])) * _ipow(_scaled(k, K_DIGITS), level - 1)
	return _round_step(num, digits, _ladder_step(num, digits, ladder))


## round_rule(seed x k^(L-1)) on a single fixed step.
func _curve_step(seed: float, seed_field: String, k: float, level: int, step: float) -> float:
	var digits: int = int(SEED_DIGITS[seed_field]) + K_DIGITS * (level - 1)
	var num := _scaled(seed, int(SEED_DIGITS[seed_field])) * _ipow(_scaled(k, K_DIGITS), level - 1)
	return _round_step(num, digits, _step_parts(step))


# --------------------------------------------------------------------------
# Regeneration of one published cell from the seed rows (doc 02 §2.2)
# --------------------------------------------------------------------------

## The `min_city_level` ladder for one growth class — the base ladder unless
## `min_city_level_by_growth_class` overrides it (doc 92 §24.3: the `steady`
## class opens its sixth rung a city level earlier than the towers do).
static func _city_ladder(rules: Dictionary, growth_class: String) -> Array:
	var overrides: Dictionary = rules.get("min_city_level_by_growth_class", {})
	if overrides.has(growth_class):
		return overrides[growth_class]
	return rules["min_city_level_by_level"]


func _expected_row(rules: Dictionary, archetype: String, level: int) -> Dictionary:
	var seed: Dictionary = rules["seed_rows"][archetype]
	var growth: Dictionary = rules["growth_classes"][String(seed["class"])]
	var shared: Dictionary = rules["shared_curves"]
	var ladders: Dictionary = rules["rounding"]
	var derived: Dictionary = rules["rounding_derived"]
	var coverage: Dictionary = rules["coverage_ladder"]

	var k_out := float(growth["k_out"])
	var k_dem := float(growth["k_dem"])
	var k_time := float(growth["k_time"])
	var multipliers: Dictionary = coverage["archetype_multiplier"]
	var arch_mult := float(multipliers.get(archetype, multipliers["default"]))
	var max_requirement := float(coverage["max_requirement"])
	var integer_step := float(derived["population"])

	var expected := {
		"population": _curve_step(float(seed["pop"]), "pop", k_out, level, integer_step),
		"jobs": _curve_step(float(seed["jobs"]), "jobs", k_out, level, integer_step),
		"power_demand_kw": _curve_ladder(float(seed["power_kw"]), "power_kw", k_dem, level, ladders["kw"]),
		"water_demand": _curve_ladder(float(seed["water"]), "water", k_dem, level, ladders["wu"]),
		"build_time_hours": _curve_ladder(float(seed["time_h"]), "time_h", k_time, level, ladders["time_h"]),
		"decay_per_hour": _curve_ladder(float(seed["decay"]), "decay", float(shared["k_decay"]), level, ladders["decay"]),
		"fire_ignition_per_hour": _curve_step(float(seed["fire_p"]), "fire_p",
				float(shared["k_fire_rate"]), level, float(derived["fire_ignition_per_hour"])),
		"fire_load": _curve_step(float(seed["fire_load"]), "fire_load",
				float(shared["k_fire_load"]), level, float(derived["fire_load"])),
		"crime_weight": _curve_step(float(seed["crime"]), "crime",
				float(shared["k_crime"]), level, float(derived["crime_weight"])),
		"min_city_level": float(maxi(int(seed["min_city"]),
				int(_city_ladder(rules, String(seed["class"]))[level - 1]))),
	}

	var requirement_step := _step_parts(float(derived["coverage_requirement"]))
	for pair in [["fire", "req_fire_coverage"], ["police", "req_police_coverage"]]:
		var ladder_value := float(coverage[pair[0]][level - 1])
		var num := _scaled(ladder_value, COVERAGE_DIGITS) * _scaled(arch_mult, COVERAGE_DIGITS)
		expected[pair[1]] = minf(
				_round_step(num, COVERAGE_DIGITS * 2, requirement_step), max_requirement)

	if seed.has("coverage_radius"):
		expected["coverage_radius_tiles"] = _curve_step(float(seed["coverage_radius"]),
				"coverage_radius", float(shared["k_radius"]), level,
				float(derived["coverage_radius_tiles"]))

	# upgrade_time(L->L+1) = build_time(L+1) x 0.65, from the ROUNDED build_time
	# cell (doc 02 §2.2; the raw-product reading misses 3 of the 48 cells).
	if level < _levels_of(archetype):
		var next_build := _curve_ladder(float(seed["time_h"]), "time_h", k_time, level + 1,
				ladders["time_h"])
		var factor := float(shared["upgrade_time_factor"])
		var num := _scaled(next_build, BUILD_TIME_DIGITS) * _scaled(factor, UPGRADE_FACTOR_DIGITS)
		var digits := BUILD_TIME_DIGITS + UPGRADE_FACTOR_DIGITS
		expected["upgrade_time_hours"] = _round_step(num, digits,
				_ladder_step(num, digits, ladders["time_h"]))
	return expected


# --------------------------------------------------------------------------
# (a) The diff test — doc 02 §7 test 2
# --------------------------------------------------------------------------

func test_curve_consistency_all_66_rows() -> void:
	var catalog := _catalog()
	var rules := _rules_data()
	var checked := 0
	for archetype in ARCHETYPES:
		for level in range(1, _levels_of(archetype) + 1):
			var shipped := catalog.stats(archetype, level)
			assert_false(shipped.is_empty(), "%s L%d must exist" % [archetype, level])
			var expected := _expected_row(rules, archetype, level)
			for column in CURVE_COLUMNS:
				if not expected.has(column):
					assert_false(shipped.has(column),
							"%s L%d must not carry %s" % [archetype, level, column])
					continue
				assert_true(shipped.has(column),
						"%s L%d missing %s" % [archetype, level, column])
				# RR-19: no exceptions — every cell is pure regeneration.
				var want := float(expected[column])
				assert_almost_eq(float(shipped[column]), want, EPS,
						"%s L%d %s regenerated from seed_rows" % [archetype, level, column])
				checked += 1
	assert_true(checked >= 66 * 12, "swept every generated cell, got %d" % checked)


func test_rr19_corrected_cells_follow_the_rules() -> void:
	# Report 98 RR-19 made the §2.2 rules canonical and corrected the four cells
	# doc 02 used to publish against them. This asserts the correction stuck in
	# both directions: the cell equals what the rules generate, and it is not
	# back at the figure the doc printed before the ruling.
	var catalog := _catalog()
	var rules := _rules_data()
	assert_eq(RR19_CORRECTIONS.size(), 4, "RR-19 corrected four cells")
	for entry in RR19_CORRECTIONS:
		var archetype := String(entry["archetype"])
		var level := int(entry["level"])
		var field := String(entry["field"])
		var shipped := float(catalog.stats(archetype, level)[field])
		assert_almost_eq(shipped, float(entry["now"]), EPS,
				"%s L%d %s ships the rule-generated value (%s)"
				% [archetype, level, field, str(entry["arithmetic"])])
		assert_true(absf(shipped - float(entry["was"])) > EPS,
				"%s L%d %s regressed to the pre-RR-19 published value %s"
				% [archetype, level, field, str(entry["was"])])
		var expected := _expected_row(rules, archetype, level)
		assert_almost_eq(float(expected[field]), float(entry["now"]), EPS,
				"%s L%d %s: regeneration from seed_rows agrees with RR-19"
				% [archetype, level, field])


func test_rounding_regimes_sampled() -> void:
	# At least one named cell per rounding regime in doc 02 §2.2, with the
	# arithmetic spelled out so a failure is readable without the doc.
	var catalog := _catalog()
	var samples := [
		["house", 1, "power_demand_kw", 3.0, "kW <10 -> 0.5: 3 x 2.35^0 = 3"],
		["house", 2, "power_demand_kw", 7.0, "kW <10 -> 0.5: 3 x 2.35 = 7.05"],
		["house", 5, "power_demand_kw", 91.0, "kW <100 -> 1: 3 x 2.35^4 = 91.494"],
		["apartment", 3, "power_demand_kw", 130.0, "kW <1000 -> 5: 22 x 2.45^2 = 132.055"],
		["high_rise", 4, "power_demand_kw", 1490.0, "kW <10000 -> 10: 90 x 2.55^3 = 1492.324"],
		["data_center", 5, "power_demand_kw", 16900.0, "kW >=10000 -> 50: 400 x 2.55^4 = 16913.0025"],
		["house", 2, "water_demand", 0.19, "WU <1 -> 0.01: 0.08 x 2.35 = 0.188"],
		["high_rise", 2, "water_demand", 3.3, "WU <10 -> 0.1: 1.28 x 2.55 = 3.264 (seed 1.28, not cell 1.3)"],
		["high_rise", 5, "water_demand", 54.0, "WU <100 -> 0.5: 1.28 x 2.55^4 = 54.121608"],
		["data_center", 5, "water_demand", 135.0, "WU >=100 -> 1: 3.2 x 2.55^4 = 135.30402"],
		["house", 4, "build_time_hours", 5.5, "time <20 -> 0.5: 2 x 1.4^3 = 5.488"],
		["office", 5, "build_time_hours", 46.0, "time >=20 -> 1: 8 x 1.55^4 = 46.176"],
		["office", 4, "upgrade_time_hours", 30.0, "upgrade: round(build(5)=46) x 0.65 = 29.9 -> 30"],
		["substation", 5, "decay_per_hour", 0.001659, "decay 6 dp: 0.0008 x 1.2^4 = 0.00165888"],
		["data_center", 4, "fire_ignition_per_hour", 0.00126, "fire 5 dp: 0.0006 x 1.28^3 = 0.001258291"],
		["store", 5, "crime_weight", 19.66, "crime 2 dp: 3.0 x 1.6^4 = 19.6608"],
		["high_rise", 5, "population", 1167.0, "int: 60 x 2.1^4 = 1166.886"],
		["office", 2, "jobs", 56.0, "int TIE half-up: 30 x 1.85 = 55.5 -> 56"],
		["high_rise", 2, "jobs", 32.0, "int TIE half-up: 15 x 2.1 = 31.5 -> 32"],
		["construction_yard", 2, "coverage_radius_tiles", 38.0, "radius TIE half-up: 30 x 1.25 = 37.5 -> 38"],
		["police_station", 4, "coverage_radius_tiles", 39.0, "radius: 20 x 1.25^3 = 39.0625"],
		["fire_station", 2, "coverage_radius_tiles", 23.0, "radius TIE half-up: 18 x 1.25 = 22.5 -> 23 (RR-19)"],
		["water_facility", 2, "jobs", 19.0, "int TIE half-up: 10 x 1.85 = 18.5 -> 19 (RR-19)"],
		["house", 4, "fire_ignition_per_hour", 0.00031, "fire 5 dp: 0.00015 x 1.28^3 = 0.000314573 (RR-19)"],
		["construction_yard", 3, "fire_ignition_per_hour", 0.00066, "fire 5 dp: 0.0004 x 1.28^2 = 0.00065536 (RR-19)"],
		["high_rise", 5, "fire_load", 1120.0, "fire_load doubles: 70 x 2^4 = 1120"],
		["high_rise", 5, "req_fire_coverage", 0.95, "clamped: 0.80 x 1.25 = 1.00 -> max_requirement 0.95"],
		["police_station", 5, "req_police_coverage", 0.56, "0.75 x 0.75 = 0.5625 -> 0.56"],
	]
	assert_true(samples.size() >= 15, "at least 15 sampled cells")
	for sample in samples:
		var shipped := catalog.stats(String(sample[0]), int(sample[1]))
		assert_almost_eq(float(shipped[String(sample[2])]), float(sample[3]), EPS,
				"%s L%d %s — %s" % [sample[0], sample[1], sample[2], sample[4]])


func test_water_seeds_published() -> void:
	# Doc 02 §7 test 2b / RR-8: the unrounded seeds are the generation input and
	# three of them differ from their displayed L1 cell.
	var catalog := _catalog()
	var rules := _rules_data()
	var seeds: Dictionary = rules["seed_rows"]
	assert_almost_eq(float(seeds["store"]["water"]), 0.128, 1e-12, "store water seed")
	assert_almost_eq(float(seeds["high_rise"]["water"]), 1.28, 1e-12, "high_rise water seed")
	assert_almost_eq(float(seeds["police_station"]["water"]), 0.192, 1e-12, "police water seed")
	var differs := {"store": 0.13, "high_rise": 1.3, "police_station": 0.19}
	for archetype in ARCHETYPES:
		var seed := float(seeds[archetype]["water"])
		var shown := _curve_ladder(seed, "water", 1.0, 1, rules["rounding"]["wu"])
		assert_almost_eq(float(catalog.stats(archetype, 1)["water_demand"]), shown, EPS,
				"%s L1 water_demand == round_wu(seed)" % archetype)
		if differs.has(archetype):
			assert_almost_eq(shown, float(differs[archetype]), EPS,
					"%s display cell differs from its seed (RR-8)" % archetype)
			assert_true(absf(shown - seed) > EPS,
					"%s seed and display cell must differ (RR-8)" % archetype)
		else:
			assert_almost_eq(shown, seed, EPS,
					"%s seed and display cell coincide" % archetype)


# --------------------------------------------------------------------------
# (b) Published-value spot checks
# --------------------------------------------------------------------------

func test_water_anchor() -> void:
	# Doc 02 §7 test 6 / C-34: the per-capita anchor doc 05 §2.13 arbitrates against.
	var catalog := _catalog()
	assert_almost_eq(float(catalog.stats("house", 1)["water_demand"]), 0.08, EPS,
			"house L1 = 4 residents x 0.020 m3/h")
	assert_almost_eq(float(catalog.stats("apartment", 1)["water_demand"]), 0.48, EPS,
			"apartment L1 = 24 residents x 0.020 m3/h")


func test_signature_published_cells() -> void:
	var catalog := _catalog()
	assert_almost_eq(float(catalog.stats("data_center", 5)["power_demand_kw"]), 16900.0, EPS,
			"doc 02 §2.4 signature balance fact: L5 data center draws 16,900 kW")
	assert_almost_eq(float(catalog.stats("data_center", 5)["water_demand"]), 135.0, EPS,
			"…and 135 m3/h")
	assert_eq(catalog.stats("high_rise", 5)["fire_load"], 1120,
			"doc 02 §2.7 E5: high_rise L5 fire_load = 56 x house L1's 20")
	assert_eq(catalog.stats("house", 1)["fire_load"], 20, "the S_req_base anchor")
	# Doc 02 §2.5 worked example E1.
	assert_almost_eq(float(catalog.stats("apartment", 3)["power_demand_kw"]), 130.0, EPS, "E1 power")
	assert_almost_eq(float(catalog.stats("apartment", 3)["water_demand"]), 2.9, EPS, "E1 water")
	assert_eq(catalog.stats("apartment", 3)["population"], 82, "E1 population")
	assert_eq(catalog.stats("apartment", 3)["jobs"], 7, "E1 jobs")
	# Doc 02 §2.11 worked example E2: the signature upgrade gate.
	var delta_power := float(catalog.stats("apartment", 3)["power_demand_kw"]) \
			- float(catalog.stats("apartment", 2)["power_demand_kw"])
	assert_almost_eq(delta_power, 76.0, EPS, "E2 delta_power = 130 - 54")


func test_fire_load_doubles_every_level() -> void:
	# Doc 02 §7 test 24: k_fire_load = 2.00 for all 66 rows.
	var catalog := _catalog()
	for archetype in ARCHETYPES:
		for level in range(2, _levels_of(archetype) + 1):
			assert_eq(catalog.stats(archetype, level)["fire_load"],
					int(catalog.stats(archetype, level - 1)["fire_load"]) * 2,
					"%s L%d fire_load doubles" % [archetype, level])


func test_demand_growth_invariant() -> void:
	# Doc 02 §7 test 4 / report 98 C-13 — the most important assertion here.
	var rules := _rules_data()
	var tax_growth := float(rules["demand_growth_invariant"]["must_exceed_value"])
	assert_almost_eq(tax_growth, 2.15, EPS, "mirror of doc 03's TAX_LEVEL_GROWTH")
	var classes: Dictionary = rules["growth_classes"]
	for class_name_variant in classes:
		assert_true(float(classes[class_name_variant]["k_dem"]) > tax_growth,
				"growth class %s: k_dem must exceed TAX_LEVEL_GROWTH" % class_name_variant)
	assert_true(float(classes["steady"]["k_dem"]) < float(classes["standard"]["k_dem"]),
			"taller classes degrade efficiency faster: steady < standard")
	assert_true(float(classes["standard"]["k_dem"]) < float(classes["vertical"]["k_dem"]),
			"taller classes degrade efficiency faster: standard < vertical")


func test_k_dem_ordering_holds_in_the_shipped_table() -> void:
	# Doc 02 §2.2's guarantee, read back off the table rather than the constants:
	# every archetype's L5 demand is at least the slowest class's 2.35^4 = 30.498
	# times its L1 demand. The 2 % slack is the display-rounding ladder: house
	# water rounds 0.08 -> 2.4 (30.0x) and store's L1 cell rounds 0.128 up to 0.13.
	var catalog := _catalog()
	var slowest := pow(2.35, 4)
	var tolerance := 0.98
	var compared := 0
	for archetype in ARCHETYPES:
		var first := catalog.stats(archetype, 1)
		var last := catalog.stats(archetype, 5)
		for column in ["power_demand_kw", "water_demand"]:
			var base := float(first[column])
			if base <= 0.0:
				continue  # substation and power_facility draw no power; substation no water
			var ratio := float(last[column]) / base
			assert_true(ratio >= slowest * tolerance,
					"%s %s: L5/L1 = %f must be >= 2.35^4 (%f) within rounding"
					% [archetype, column, ratio, slowest])
			compared += 1
	assert_true(compared >= 20, "compared %d demand ladders" % compared)
	# substation is the one archetype with no demand at all (doc 02 §2.3).
	assert_almost_eq(float(catalog.stats("substation", 5)["power_demand_kw"]), 0.0, EPS)
	assert_almost_eq(float(catalog.stats("substation", 5)["water_demand"]), 0.0, EPS)


# --------------------------------------------------------------------------
# (d) Structure — doc 02 §7 tests 1, 3, 6b
# --------------------------------------------------------------------------

func test_catalog_loads() -> void:
	var catalog := _catalog()
	assert_eq(catalog.archetypes().size(), 12, "spec §43.2: 12 MVP archetypes")
	assert_eq(catalog.max_level(), 6,
			"Core Design Rule 5 as amended (doc 92 §24): the tallest ladder is six")
	assert_eq(catalog.schema_version(), 1, "buildings.json schema_version")
	var sorted_ids := ARCHETYPES.duplicate()
	sorted_ids.sort()
	var listed: Array = catalog.archetypes()
	assert_eq(listed.size(), sorted_ids.size(), "archetypes() lists them all")
	for i in sorted_ids.size():
		assert_eq(String(listed[i]), String(sorted_ids[i]), "archetypes() is sorted")
	for archetype in ARCHETYPES:
		assert_true(catalog.has(archetype), "has(%s)" % archetype)
		var top := _levels_of(archetype)
		assert_eq(catalog.levels(archetype).size(), top,
				"%s has %d levels" % [archetype, top])
		assert_eq(catalog.max_level_of(archetype), top,
				"%s: max_level_of agrees with the row count" % archetype)
		for level in range(1, top + 1):
			assert_eq(catalog.stats(archetype, level)["level"], level,
					"%s levels are ascending" % archetype)
			assert_eq(catalog.is_top_level(archetype, level), level == top,
					"%s L%d is_top_level" % [archetype, level])
		assert_true(catalog.stats(archetype, top + 1).is_empty(),
				"%s has no L%d" % [archetype, top + 1])
		assert_true(catalog.stats(archetype, 0).is_empty(), "%s has no L0" % archetype)
	assert_false(catalog.has("stadium"), "deferred archetypes are absent")
	assert_true(catalog.stats("stadium", 1).is_empty(), "unknown archetype -> {}")


func test_every_published_column_is_present() -> void:
	var catalog := _catalog()
	var required := [
		"level", "footprint", "population", "jobs", "power_demand_kw", "water_demand",
		"build_time_hours", "decay_per_hour", "fire_ignition_per_hour", "fire_load",
		"crime_weight", "req_fire_coverage", "req_police_coverage", "min_city_level",
	]
	var radius_archetypes := ["police_station", "fire_station", "construction_yard"]
	for archetype in ARCHETYPES:
		var info := catalog.archetype_info(archetype)
		for key in ["name", "category", "tax_class", "growth_class", "produces"]:
			assert_true(info.has(key) and not str(info[key]).is_empty(),
					"%s carries %s" % [archetype, key])
		var top := _levels_of(archetype)
		for level in range(1, top + 1):
			var row := catalog.stats(archetype, level)
			for column in required:
				assert_true(row.has(column), "%s L%d carries %s" % [archetype, level, column])
			assert_eq(row.has("upgrade_time_hours"), level < top,
					"%s L%d upgrade_time_hours presence" % [archetype, level])
			assert_eq(row.has("coverage_radius_tiles"), radius_archetypes.has(archetype),
					"%s L%d coverage_radius_tiles presence" % [archetype, level])
			var footprint: Array = row["footprint"]
			assert_eq(footprint.size(), 2, "%s L%d footprint is [w, h]" % [archetype, level])
			assert_true(int(footprint[0]) >= 1 and int(footprint[0]) <= 4,
					"%s L%d footprint within constitution §6's 1..4" % [archetype, level])
			assert_true(float(row["decay_per_hour"]) < 0.01,
					"%s L%d decay_per_hour on the [0,1] scale" % [archetype, level])


func test_no_deleted_columns() -> void:
	# Doc 02 §7 test 3: a silently reverted ruling must fail loudly.
	var text := FileAccess.get_file_as_string(BUILDINGS_PATH)
	var data := _buildings_data()
	for column in DELETED_COLUMNS:
		for archetype in ARCHETYPES:
			var entry: Dictionary = data["archetypes"][archetype]
			assert_false(entry.has(column),
					"%s must not carry deleted field %s" % [archetype, column])
			for row in entry["levels"]:
				assert_false((row as Dictionary).has(column),
						"%s level row must not carry deleted field %s" % [archetype, column])
	# The audit trail names them, so a bare substring scan would false-positive.
	assert_true(text.contains("\"rr19_corrected_cells\""),
			"the generated metadata records RR-19's four corrected cells")


func test_water_facility_variants_and_reference_footprints() -> void:
	# Doc 02 §7 test 6b (the part this catalog owns) / RR-8.
	var catalog := _catalog()
	var expected_variants := ["source", "treatment", "pump", "tank", "booster"]
	var variants: Array = catalog.water_variants()
	assert_eq(variants.size(), expected_variants.size(), "C-35 variant list size")
	for i in expected_variants.size():
		assert_eq(String(variants[i]), String(expected_variants[i]), "C-35 variant list order")
	assert_eq(catalog.reference_water_variant(), "pump", "RR-8 reference variant")
	assert_true(catalog.is_water_variant("tank"))
	assert_false(catalog.is_water_variant("cistern"))
	var expected_footprints := [[3, 3], [3, 3], [3, 3], [3, 3], [4, 4]]
	for level in range(1, 6):
		var footprint: Array = catalog.stats("water_facility", level)["footprint"]
		var want: Array = expected_footprints[level - 1]
		assert_eq(int(footprint[0]), int(want[0]),
				"water_facility L%d is the `pump` reference footprint width" % level)
		assert_eq(int(footprint[1]), int(want[1]),
				"water_facility L%d is the `pump` reference footprint height" % level)
	# No per-variant footprint table lives in buildings.json (RR-8 / F-08).
	var entry: Dictionary = _buildings_data()["archetypes"]["water_facility"]
	assert_true(bool(entry["footprints_are_reference_variant_only"]),
			"the footprint ladder is flagged reference-variant-only")
	assert_true(String(entry["per_variant_footprint_source"]).contains("water.json"),
			"per-variant footprints point at doc 05")
	for other in ARCHETYPES:
		if other == "water_facility":
			continue
		assert_false(catalog.archetype_info(other).has("variants"),
				"%s must not declare variants" % other)


func test_footprint_and_city_level_growth_schedule() -> void:
	# Doc 02 §6: footprint grows at store L3, power L4, yard L4, water L5 only.
	var catalog := _catalog()
	var expected_growth := {"store": 3, "power_facility": 4, "construction_yard": 4,
			"water_facility": 5}
	var growth_steps := {}
	for archetype in ARCHETYPES:
		for level in range(2, _levels_of(archetype) + 1):
			var before: Array = catalog.stats(archetype, level - 1)["footprint"]
			var after: Array = catalog.stats(archetype, level)["footprint"]
			assert_true(int(after[0]) >= int(before[0]) and int(after[1]) >= int(before[1]),
					"%s L%d footprint never shrinks" % [archetype, level])
			if int(after[0]) != int(before[0]) or int(after[1]) != int(before[1]):
				growth_steps[archetype] = level
			assert_true(int(catalog.stats(archetype, level)["min_city_level"])
					>= int(catalog.stats(archetype, level - 1)["min_city_level"]),
					"%s L%d min_city_level never decreases" % [archetype, level])
	assert_eq(growth_steps.size(), expected_growth.size(),
			"exactly four footprint growth steps (doc 02 §6)")
	for archetype in expected_growth:
		assert_eq(int(growth_steps.get(archetype, -1)), int(expected_growth[archetype]),
				"%s footprint grows at L%d" % [archetype, int(expected_growth[archetype])])


func test_rules_blocks_present() -> void:
	var rules := _rules_data()
	assert_eq(int(rules["schema_version"]), 2, "building_rules.json schema_version")
	for block in ["growth_classes", "shared_curves", "coverage_ladder", "condition",
			"fire", "construction", "state_modifiers", "seed_rows", "rounding",
			"headroom_safety", "avenue_gate", "safety_coverage_factor",
			"min_city_level_by_level", "min_city_level_by_growth_class",
			"sixth_level_archetypes", "water_facility_variants"]:
		assert_true(rules.has(block), "building_rules carries §8 block '%s'" % block)
	# §2.12 STATE_* tables: eight rows, each with the four modifier channels.
	var states: Dictionary = rules["state_modifiers"]
	assert_eq(states.size(), 8, "eight state_modifier rows (doc 02 §2.12)")
	for state_variant in states:
		for channel in ["output", "demand", "occupancy", "coverage"]:
			assert_true((states[state_variant] as Dictionary).has(channel),
					"state %s carries '%s'" % [state_variant, channel])
	assert_almost_eq(float(states["under_construction_upgrade"]["demand"]), 1.00, EPS,
			"an upgrading tower keeps drawing its old load")
	assert_almost_eq(float(states["under_construction_upgrade"]["output"]), 0.35, EPS,
			"…while producing a third of its old output")
	assert_almost_eq(float(states["under_construction_new"]["water_demand"]), 0.10, EPS,
			"site water during a new build")
	# §2.6 condition constants live on [0,1] (doc 02 §7 test 5). The §8 block also
	# stores rate multipliers under `condition` (damaged_decay_multiplier = 1.50),
	# so the scale check applies to the constants expressed ON that scale.
	var condition: Dictionary = rules["condition"]
	for key in BuildingCatalog.CONDITION_SCALE_KEYS:
		assert_true(condition.has(key), "condition block carries '%s'" % key)
		var value := float(condition[key])
		assert_true(value >= 0.0 and value <= 1.0,
				"condition.%s = %f is on [0,1]" % [key, value])
	assert_almost_eq(float(condition["damaged_decay_multiplier"]), 1.50, EPS,
			"a damaged building decays 50 %% faster — a multiplier, not a condition")
	assert_almost_eq(float(condition["auto_damage_threshold"]), 0.35, EPS)
	assert_almost_eq(float(condition["min_condition_to_upgrade"]), 0.55, EPS)
	# §2.7 RR-9: the S_req_base exponent stays at 0.45.
	assert_almost_eq(float(rules["fire"]["s_req_base_exponent"]), 0.45, EPS,
			"report 98 RR-9 LOCKED the exponent at 0.45")
	var s_req := float(rules["fire"]["s_req_base_coefficient"]) \
			* pow(1120.0 / float(rules["fire"]["s_req_base_anchor_fire_load"]), 0.45)
	assert_almost_eq(s_req, 3.06, 0.01,
			"S_req_base(high_rise L5) = 0.50 x 56^0.45 = 3.06, not the void '~3.6' gloss")
	# §2.13 / §2.10 construction & refund constants.
	var construction: Dictionary = rules["construction"]
	assert_eq(int(construction["work_units_per_crew_hour"]), 100)
	assert_almost_eq(float(construction["refund_fraction_planned"]), 1.00, EPS)
	assert_almost_eq(float(construction["refund_fraction_under_construction_new"]), 0.60, EPS)
	assert_almost_eq(float(construction["refund_fraction_under_construction_upgrade"]), 0.50, EPS)
	assert_eq(int(construction["rebuild_grace_hours"]), 72)
	# §2.11 headroom margins and the E_AVENUE gate.
	assert_almost_eq(float(rules["headroom_safety"]["power"]), 1.15, EPS)
	assert_almost_eq(float(rules["headroom_safety"]["water"]), 1.10, EPS)
	assert_eq(int(rules["avenue_gate"]["min_level"]), 4)
	assert_eq(String(rules["avenue_gate"]["road_class"]), "AVENUE")
	# §2.5 safety coverage factor bounds.
	assert_almost_eq(float(rules["safety_coverage_factor"]["floor"]), 0.80, EPS)
	assert_almost_eq(float(rules["safety_coverage_factor"]["span"]), 0.20, EPS)


func test_coverage_reach_table() -> void:
	# Doc 02 §2.4 — the only "special output" column this doc still owns.
	var catalog := _catalog()
	var published := {
		"police_station": [20, 25, 31, 39, 49],
		"fire_station": [18, 23, 28, 35, 44],  # L2 corrected 22 -> 23 by RR-19
		"construction_yard": [30, 38, 47, 59, 73],
	}
	for archetype in published:
		for level in range(1, 6):
			assert_eq(catalog.stats(archetype, level)["coverage_radius_tiles"],
					int(published[archetype][level - 1]),
					"%s L%d coverage_radius_tiles" % [archetype, level])


func test_coverage_worked_example_e6() -> void:
	# Doc 02 §2.9 worked example E6, re-derived at the RR-19 radius of 23:
	# an L2 fire station (2/2 engines, condition 0.90) covering an L4 office
	# 11 tiles away must clear the office's 0.60 requirement by 0.027.
	var catalog := _catalog()
	var coverage: Dictionary = _rules_data()["coverage_ladder"]
	var radius := float(catalog.stats("fire_station", 2)["coverage_radius_tiles"])
	assert_almost_eq(radius, 23.0, EPS, "E6 runs at the corrected L2 radius")

	var distance := 11.0
	var falloff := 1.0 - pow(distance / radius, float(coverage["falloff_exponent"]))
	assert_almost_eq(falloff, 0.669252, 5e-7, "1 - (11/23)^1.5")
	var condition := 0.90
	var station_factor := float(coverage["station_condition_floor"]) \
			+ float(coverage["station_condition_span"]) * clampf(
			(condition - float(coverage["station_condition_low_anchor"]))
			/ float(coverage["station_condition_range"]), 0.0, 1.0)
	assert_almost_eq(station_factor, 0.9375, EPS, "0.50 + 0.50 x (0.70/0.80)")
	var staffing := 1.0  # doc 06 capacity_per_station_level[1] = 2 engines, 2 housed
	var c := falloff * staffing * station_factor
	assert_almost_eq(c, 0.627424, 5e-7, "E6 c = 0.627 (was 0.606 at radius 22)")

	var required := float(catalog.stats("office", 4)["req_fire_coverage"])
	assert_almost_eq(required, 0.60, EPS, "office L4 requires 0.60 x 1.00")
	assert_almost_eq(c - required, 0.027424, 5e-7,
			"E6 passes by 0.027 (was 0.006 before RR-19)")

	# The condition at which the gate closes, inverting the same chain.
	var needed_factor := required / falloff
	var threshold := float(coverage["station_condition_low_anchor"]) \
			+ float(coverage["station_condition_range"]) \
			* (needed_factor - float(coverage["station_condition_floor"])) \
			/ float(coverage["station_condition_span"])
	assert_almost_eq(threshold, 0.834437, 5e-7,
			"the upgrade gate closes below station condition 0.834 (was 0.885)")

	# Losing one engine still collapses the coverage, which is E6's real lesson.
	assert_true(falloff * 0.5 * station_factor < required,
			"one engine dispatched away drops c to 0.314 and closes the gate")


func test_load_from_files() -> void:
	var catalog := BuildingCatalog.load_from_files()
	assert_true(catalog.is_valid(), "load_from_files: " + ", ".join(catalog.errors))
	assert_eq(catalog.archetypes().size(), 12)
	assert_eq(catalog.growth_class("high_rise"), "vertical")
	assert_eq(catalog.growth_class("house"), "steady")
	assert_eq(catalog.tax_class("data_center"), "tech")
	assert_eq(catalog.category("data_center"), "industrial")
	assert_eq(int(catalog.rules()["schema_version"]), 2)


# --------------------------------------------------------------------------
# (c) Malformed fixtures are rejected
# --------------------------------------------------------------------------

func _expect_rejected(label: String, buildings: Dictionary, rules: Dictionary) -> void:
	var catalog := BuildingCatalog.new(buildings, rules)
	assert_false(catalog.is_valid(), "malformed fixture must be rejected: " + label)


func test_malformed_fixtures_rejected() -> void:
	var pristine := BuildingCatalog.new(_buildings_data(), _rules_data())
	assert_true(pristine.is_valid(), "control: " + ", ".join(pristine.errors))

	var data := _buildings_data()
	data["archetypes"].erase("house")
	_expect_rejected("only 11 archetypes", data, _rules_data())

	data = _buildings_data()
	(data["archetypes"]["house"]["levels"] as Array).remove_at(5)
	_expect_rejected("house has 5 levels but is declared six-level", data, _rules_data())

	data = _buildings_data()
	(data["archetypes"]["police_station"]["levels"] as Array).remove_at(4)
	_expect_rejected("police_station has 4 levels", data, _rules_data())

	# Doc 92 §24.2: the sixth rung exists exactly where the rules say it does.
	# A ladder that grew a row the rules did not sanction is a schema break,
	# not a content addition — the mesh set and the money table would not know.
	data = _buildings_data()
	var sixth: Dictionary = (data["archetypes"]["house"]["levels"] as Array)[5]
	var smuggled: Dictionary = sixth.duplicate()
	smuggled["level"] = 6
	(data["archetypes"]["police_station"]["levels"] as Array).append(smuggled)
	data["generated"]["levels_by_archetype"]["police_station"] = 6
	_expect_rejected("a sixth rung the rules do not sanction", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["levels"][5]["upgrade_time_hours"] = 3.0
	_expect_rejected("upgrade_time_hours at the top level", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["levels"][4].erase("upgrade_time_hours")
	_expect_rejected("upgrade_time_hours missing below the top level", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["levels"][2].erase("upgrade_time_hours")
	_expect_rejected("upgrade_time_hours missing at level 3", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["levels"][0]["decay_per_hour"] = 0.045
	_expect_rejected("decay on the old [0,100] scale", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["store"]["levels"][3]["footprint"] = [1, 1]
	_expect_rejected("footprint shrinks from store L3's 2x2 to L4's 1x1", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["levels"][3]["min_city_level"] = 1
	_expect_rejected("min_city_level decreases", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["office"]["levels"][0]["build_cost"] = 13000
	_expect_rejected("reintroduced build_cost (C-07)", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["police_station"]["levels"][0]["unit_slots"] = 2
	_expect_rejected("reintroduced unit_slots (C-50)", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["variants"] = ["a", "b"]
	_expect_rejected("variants on a non-water archetype", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["water_facility"].erase("variants")
	_expect_rejected("water_facility without variants", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["water_facility"]["reference_variant"] = "cistern"
	_expect_rejected("reference_variant not in the variant list", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["category"] = "villa"
	_expect_rejected("unknown category", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["growth_class"] = "explosive"
	_expect_rejected("growth_class absent from building_rules", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["levels"][1]["population"] = -6
	_expect_rejected("negative population", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["levels"][1]["population"] = 6.5
	_expect_rejected("fractional population", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["levels"][1]["level"] = 4
	_expect_rejected("levels out of order", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["levels"][1].erase("water_demand")
	_expect_rejected("missing water_demand column", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["levels"][1]["footprint"] = [0, 1]
	_expect_rejected("zero-width footprint", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["house"]["levels"][1]["coverage_radius_tiles"] = 12
	_expect_rejected("coverage radius on a house", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["police_station"]["levels"][1].erase("coverage_radius_tiles")
	_expect_rejected("police station without a coverage radius", data, _rules_data())

	data = _buildings_data()
	data["archetypes"]["high_rise"]["levels"][4]["req_fire_coverage"] = 1.00
	_expect_rejected("requirement above max_requirement", data, _rules_data())

	data = _buildings_data()
	data.erase("schema_version")
	_expect_rejected("no schema_version", data, _rules_data())

	# Rules-side fixtures.
	var rules := _rules_data()
	rules["growth_classes"]["vertical"]["k_dem"] = 2.10
	_expect_rejected("k_dem below TAX_LEVEL_GROWTH (C-13)", _buildings_data(), rules)

	rules = _rules_data()
	rules.erase("state_modifiers")
	_expect_rejected("missing §8 block", _buildings_data(), rules)

	rules = _rules_data()
	rules["condition"]["band_good"] = 85.0
	_expect_rejected("condition constant on the old [0,100] scale", _buildings_data(), rules)

	rules = _rules_data()
	rules["water_facility_reference_variant"] = "cistern"
	_expect_rejected("rules reference_variant not in the list", _buildings_data(), rules)

	rules = _rules_data()
	(rules["state_modifiers"]["active"] as Dictionary).erase("occupancy")
	_expect_rejected("STATE_OCCUPANCY entry missing", _buildings_data(), rules)

	_expect_rejected("empty documents", {}, {})


func test_stats_are_read_only() -> void:
	# `stats()` is a shared lookup, so the rows must not be mutable by a caller.
	var catalog := _catalog()
	var row := catalog.stats("house", 1)
	assert_true(row.is_read_only(), "level rows are read-only")
	assert_true((row["footprint"] as Array).is_read_only(), "footprints are read-only")
	assert_true(catalog.archetype_info("house").is_read_only(), "metadata is read-only")


func test_water_footprint_cross_check_against_doc_05() -> void:
	# RR-8: doc 02's water_facility footprint row must equal doc 05's
	# components.pump. data/water.json is doc 05's and does not exist yet, so the
	# check runs against a stub here and against the real file once it lands.
	var catalog := _catalog()
	var matching := {"components": {"pump": [
		{"footprint_w": 3, "footprint_h": 3}, {"footprint_w": 3, "footprint_h": 3},
		{"footprint_w": 3, "footprint_h": 3}, {"footprint_w": 3, "footprint_h": 3},
		{"footprint_w": 4, "footprint_h": 4},
	]}}
	assert_true(catalog.cross_check_water_footprints(matching).is_empty(),
			"doc 05's published pump ladder 3x3/3x3/3x3/3x3/4x4 matches the shell table")
	var tank_shaped := {"components": {"pump": [
		{"footprint_w": 2, "footprint_h": 2}, {"footprint_w": 2, "footprint_h": 2},
		{"footprint_w": 3, "footprint_h": 3}, {"footprint_w": 3, "footprint_h": 3},
		{"footprint_w": 4, "footprint_h": 4},
	]}}
	assert_false(catalog.cross_check_water_footprints(tank_shaped).is_empty(),
			"a tank-shaped ladder must be rejected — that is the C-35 flat-shell error")
	assert_false(catalog.cross_check_water_footprints({}).is_empty(),
			"a water.json with no components.pump is reported, not ignored")
	if FileAccess.file_exists("res://data/water.json"):
		var water: Variant = JSON.parse_string(FileAccess.get_file_as_string("res://data/water.json"))
		if water is Dictionary:
			assert_true(catalog.cross_check_water_footprints(water).is_empty(),
					"shipped data/water.json agrees with doc 02's pump reference row")


## The bug this test exists for was shipped and caught in the same wave: doc 02
## §2.6a's ownership floor reads `condition.band_worn`, `Building
## .DEFAULT_CONDITION` did not carry that key, and so an UNSTAMPED building had
## no floor — a silently different physics from a stamped one, in the exact shape
## PA-13 filed against the consts this dict replaced. A fallback that is not the
## whole authored block is not a fallback.
func test_building_default_condition_matches_the_authored_block() -> void:
	var catalog := _catalog()
	var authored := catalog.condition_rules()
	assert_false(authored.is_empty(), "data/building_rules.json carries the block")
	for key: String in Building.DEFAULT_CONDITION:
		assert_true(authored.has(key),
				"Building.DEFAULT_CONDITION carries '%s' and the file does not" % key)
		assert_almost_eq(float(authored[key]),
				float(Building.DEFAULT_CONDITION[key]), 1e-9,
				"condition.%s: the fallback and the authored value must agree" % key)
	for key: String in ["band_good", "band_worn", "band_poor",
			"auto_damage_threshold", "min_condition_to_upgrade", "repair_time_factor"]:
		assert_true(Building.DEFAULT_CONDITION.has(key),
				"every key `Building` READS must be in the fallback: '%s'" % key)


## Doc 02 §2.6a / doc 93 §Y1's ownership table, asserted archetype by archetype
## rather than by the predicate that produces it — the point of the ruling is
## WHICH buildings are on each side, and a test that re-derives the answer from
## `owner_maintenance.classes` would pass on any class list at all.
func test_the_ownership_split_is_six_and_six() -> void:
	var catalog := _catalog()
	const PRIVATE := ["house", "apartment", "store", "office", "high_rise",
			"data_center"]
	const CITY := ["police_station", "fire_station", "construction_yard",
			"power_facility", "substation", "water_facility"]
	for archetype: String in PRIVATE:
		assert_true(catalog.owner_maintained(archetype),
				"%s is private stock: its owner keeps it up" % archetype)
	for archetype: String in CITY:
		assert_false(catalog.owner_maintained(archetype),
				"%s is the city's: the city buys its repairs" % archetype)
	assert_eq(PRIVATE.size() + CITY.size(), catalog.archetypes().size(),
			"every archetype is on exactly one side of the ruling")
	# And the split is doc 03's revenue predicate, not a second opinion about it:
	# `E_building_maint` bills exactly the buildings whose owners repair them,
	# which is the observation doc 93 §Y1 is built on. Asserted against the const
	# itself, so the two lists cannot drift apart in a later wave.
	var authored: Array = (catalog.rules()["owner_maintenance"]["classes"] as Array)
	authored.sort()
	var revenue := CostCurves.REVENUE_CLASSES.duplicate()
	revenue.sort()
	assert_eq(str(authored), str(revenue),
			"owner_maintenance.classes IS CostCurves.REVENUE_CLASSES — the set "
			+ "E_building_maint bills is the set whose owners repair it")

