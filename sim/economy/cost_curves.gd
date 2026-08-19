class_name CostCurves
extends RefCounted
## The project's only cost, tax and repair price functions (doc 03 §2.3 / §2.5,
## report 98 C-07 / C-16). Pure: no state, no tick, no file IO in the
## constructor — the parsed Dictionaries are handed in, so the curves are
## testable from fixtures. `load_from_files()` is the only path that touches
## FileAccess, mirroring `BuildingCatalog`.
##
## The per-archetype columns are GENERATED — `tools/gen_building_economy.py`
## grows `base_tax_by_level`, `upgrade_cost_by_step` and `capital_value_by_level`
## from doc 03 §2.2's money table and diffs them against the doc's published
## cells. Nothing here re-derives a curve at runtime; the ladders are
## table-generation-time only. What this class does is *read* them, re-check the
## generator's invariant at load (doc 03 §7 test 8, ±$1 per cell) and apply the
## §2.5 repair/refund fractions.
##
## Loader invariants are collected in `errors` rather than raised, mirroring
## `BuildingCatalog` and `DayCurveSet`.

const LEVELS_PER_ARCHETYPE := 5
const GENERATED_CELL_TOLERANCE := 1  # doc 03 §7 test 8: ±$1 (RR-5 locks 3 cells)

## doc 03 rounds half-up everywhere (§2.8's own note: 7,187.5 → 7,188). Binary
## floats land a genuine tie a few ulp below it (5000 × 1.25 × 1.15 evaluates to
## 7187.499999999999), so the tie is resolved with an absolute epsilon. Every
## money cell in the project is authored to at most 5 decimal places, so nothing
## legitimate sits within 1e-6 of a half-dollar boundary.
const ROUND_EPSILON := 0.000001

## doc 03 §2.13(a) / §2.2 archetype ids. doc 02's roster names four of them
## differently and omits two; the alias map ships in building_economy.json.
const REQUIRED_ARCHETYPE_KEYS := [
	"class", "build_cost_l1", "base_tax_l1", "base_tax_by_level",
	"upgrade_cost_by_step", "capital_value_by_level",
]

const REVENUE_CLASSES := ["residential", "commercial", "industrial", "tech"]

var errors: PackedStringArray = []

var _archetypes: Dictionary = {}  # id -> row Dictionary
var _alias: Dictionary = {}  # doc 02 id -> doc 03 id
var _ids: Array = []
var _economy: Dictionary = {}
var _schema_version: int = 0

# doc 03 §8 constants, resolved once at load.
var _tax_level_growth: float = 0.0
var _upg_coeff: float = 0.0
var _upg_growth: float = 0.0
var _capital_value_v: Array = []
var _repair_cost_per_capital: float = 0.0
var _pm_cost_fraction: float = 0.0
var _pm_min_condition: float = 0.0
var _demolition_refund_fraction: float = 0.0
var _vehicle_resale_fraction: float = 0.0
var _land_resale_fraction: float = 0.0
var _contractor_surcharge: float = 0.0
var _road_repair_capital_fraction: float = 0.0
var _road_demolish_refund_fraction: float = 0.0
var _road_build_cost: Dictionary = {}
var _road_upgrade_cost: Dictionary = {}
var _grid_components: Dictionary = {}
var _vehicles: Dictionary = {}


func _init(building_economy: Dictionary, economy: Dictionary) -> void:
	_load(building_economy, economy)


static func load_from_files(
		building_economy_path: String = "res://data/building_economy.json",
		economy_path: String = "res://data/economy.json") -> CostCurves:
	var building_economy: Variant = JSON.parse_string(
			FileAccess.get_file_as_string(building_economy_path))
	var economy: Variant = JSON.parse_string(FileAccess.get_file_as_string(economy_path))
	var curves := CostCurves.new(
			building_economy if building_economy is Dictionary else {},
			economy if economy is Dictionary else {})
	if not (building_economy is Dictionary):
		curves.errors.append("cannot parse %s" % building_economy_path)
	if not (economy is Dictionary):
		curves.errors.append("cannot parse %s" % economy_path)
	return curves


func is_valid() -> bool:
	return errors.is_empty()


func schema_version() -> int:
	return _schema_version


func economy_data() -> Dictionary:
	return _economy


func ids() -> Array:
	return _ids.duplicate()


## Resolves a doc-02 archetype id onto its doc-03 money row; returns the id
## unchanged when it is already a doc-03 id.
func resolve_type(type: String) -> String:
	if _archetypes.has(type):
		return type
	return String(_alias.get(type, type))


func has_type(type: String) -> bool:
	return _archetypes.has(resolve_type(type))


func class_of(type: String) -> String:
	return String(_row(type).get("class", ""))


func is_revenue_producing(type: String) -> bool:
	return REVENUE_CLASSES.has(class_of(type))


func build_cost_l1(type: String) -> int:
	return int(_row(type).get("build_cost_l1", 0))


## Difficulty is applied at spend time, never baked into the table (doc 03 §2.13).
func build_cost(type: String, m_build: float = 1.0) -> int:
	return round_half_up(float(build_cost_l1(type)) * m_build)


## doc 03 §2.2 — the published, normative rows (report 98 RR-5). `level` is 1-based.
func base_tax(type: String, level: int) -> int:
	var rows: Array = _row(type).get("base_tax_by_level", [])
	if level < 1 or level > rows.size():
		return 0
	return int(rows[level - 1])


## doc 03 §2.3 — the cost of the step `from_level → from_level + 1`.
func upgrade_cost(type: String, from_level: int, m_build: float = 1.0) -> int:
	var steps: Array = _row(type).get("upgrade_cost_by_step", [])
	if from_level < 1 or from_level > steps.size():
		return 0
	return round_half_up(float(steps[from_level - 1]) * m_build)


## doc 03 §2.3 — `build_cost_l1 × V(L)`; drives maintenance, repair, refunds.
func capital_value(type: String, level: int) -> int:
	var rows: Array = _row(type).get("capital_value_by_level", [])
	if level < 1 or level > rows.size():
		return 0
	return int(rows[level - 1])


## doc 03 §2.13(b) — the price of placing one grid component at `level`.
## `level` is 1-based; components priced as a flat scalar (tie switch) ignore it.
func grid_build_cost(component: String, level: int = 1, m_build: float = 1.0) -> int:
	return CostCurves.round_half_up(float(_grid_build_cost_l(component, level)) * m_build)


## doc 03 §2.5 — a grid component's repair capital is its §2.13(b) build cost at
## the current level; grid components are replaced, not upgraded. Same table as
## `grid_build_cost`, read for a different question.
func capital_value_grid(component: String, level: int = 1) -> int:
	return _grid_build_cost_l(component, level)


func _grid_build_cost_l(component: String, level: int) -> int:
	var entry: Dictionary = _grid_components.get(component, {})
	var cost: Variant = entry.get("build_cost", null)
	if cost is Array:
		var rows: Array = cost
		if level < 1 or level > rows.size():
			return 0
		return int(rows[level - 1])
	if cost != null and not (cost is Dictionary):
		return int(cost)
	return 0


## doc 03 §2.13(b) — per-tile line costs (feeder is overhead; underground ×2.6).
func grid_line_cost_per_tile(kind: String, conductor_class: int, underground: bool = false) -> int:
	var entry: Dictionary = _grid_components.get(kind, {})
	var key := "cost_per_tile_overhead" if entry.has("cost_per_tile_overhead") else "cost_per_tile"
	var rows: Array = entry.get(key, [])
	if conductor_class < 1 or conductor_class > rows.size():
		return 0
	var cost := float(rows[conductor_class - 1])
	if underground:
		cost *= float(entry.get("underground_cost_mult", 1.0))
	return round_half_up(cost)


## doc 03 §2.5 / §2.13(d) — STREET $360, AVENUE $1,040.
func capital_value_road(road_class: String) -> int:
	return round_half_up(float(_road_build_cost.get(road_class, 0))
			* _road_repair_capital_fraction)


func road_build_cost(road_class: String, m_build: float = 1.0) -> int:
	return round_half_up(float(_road_build_cost.get(road_class, 0)) * m_build)


func road_upgrade_cost(step: String = "STREET_TO_AVENUE", m_build: float = 1.0) -> int:
	return round_half_up(float(_road_upgrade_cost.get(step, 0)) * m_build)


## doc 03 §2.5 — THE repair price of the project (report 98 C-16). Every other
## system supplies only `damage_fraction ∈ [0,1]`.
func repair_cost(capital: int, damage_fraction: float, m_repair: float = 1.0) -> int:
	var fraction := clampf(damage_fraction, 0.0, 1.0)
	return round_half_up(float(capital) * fraction * _repair_cost_per_capital * m_repair)


func repair_cost_building(type: String, level: int, damage_fraction: float,
		m_repair: float = 1.0) -> int:
	return repair_cost(capital_value(type, level), damage_fraction, m_repair)


func repair_cost_road(road_class: String, damage_fraction: float, m_repair: float = 1.0) -> int:
	return repair_cost(capital_value_road(road_class), damage_fraction, m_repair)


## doc 03 §2.5 — preventive maintenance, allowed on condition ∈ [PM_MIN, 0.99].
func pm_cost(capital: int) -> int:
	return round_half_up(float(capital) * _pm_cost_fraction)


func pm_allowed(condition: float) -> bool:
	return condition >= _pm_min_condition and condition <= 0.99


## doc 03 §2.5 — money-for-time valve, deliberately bad value.
func contractor_cost(job_cost: int) -> int:
	return round_half_up(float(job_cost) * _contractor_surcharge)


# ------------------------------------------------------------- refunds / resale

## doc 03 §2.3 — demolition returns 0.25 × capital_value. Downgrade is not permitted.
func demolition_refund(capital: int) -> int:
	return round_half_up(float(capital) * _demolition_refund_fraction)


func demolition_refund_building(type: String, level: int) -> int:
	return demolition_refund(capital_value(type, level))


## doc 03 §2.13(d) — STREET $450, AVENUE $1,300.
func road_demolish_refund(road_class: String) -> int:
	return round_half_up(float(_road_build_cost.get(road_class, 0))
			* _road_demolish_refund_fraction)


## doc 03 §2.4 / §2.13(c) — 0.40 × purchase, every type.
func vehicle_purchase(vehicle_type: String, m_build: float = 1.0) -> int:
	return round_half_up(float(_vehicles.get(vehicle_type, {}).get("purchase", 0)) * m_build)


func vehicle_resale(vehicle_type: String) -> int:
	return round_half_up(float(_vehicles.get(vehicle_type, {}).get("purchase", 0))
			* _vehicle_resale_fraction)


func vehicle_row(vehicle_type: String) -> Dictionary:
	return _vehicles.get(vehicle_type, {})


## doc 03 §2.10 — undeveloped land sells for 0.55 × current price.
func land_resale(current_price: int) -> int:
	return round_half_up(float(current_price) * _land_resale_fraction)


# ------------------------------------------------------------------- plumbing

## doc 03 rounds half-up throughout (§2.8). Symmetric about zero.
static func round_half_up(value: float) -> int:
	if value < 0.0:
		return -int(floor(-value + 0.5 + ROUND_EPSILON))
	return int(floor(value + 0.5 + ROUND_EPSILON))


func _row(type: String) -> Dictionary:
	return _archetypes.get(resolve_type(type), {})


func _load(building_economy: Dictionary, economy: Dictionary) -> void:
	_economy = economy
	_schema_version = int(building_economy.get("schema_version", 0))
	if _schema_version <= 0:
		errors.append("building_economy: missing schema_version")

	var upgrades: Dictionary = economy.get("upgrades", {})
	var tax: Dictionary = economy.get("tax", {})
	var expenses: Dictionary = economy.get("expenses", {})
	var roads: Dictionary = economy.get("roads", {})
	var land: Dictionary = economy.get("land", {})
	for block_name in ["tax", "upgrades", "expenses", "roads", "land"]:
		if not economy.has(block_name):
			errors.append("economy.json: missing block '%s'" % block_name)

	_tax_level_growth = float(tax.get("TAX_LEVEL_GROWTH", 0.0))
	_upg_coeff = float(upgrades.get("UPG_COEFF", 0.0))
	_upg_growth = float(upgrades.get("UPG_GROWTH", 0.0))
	_capital_value_v = upgrades.get("CAPITAL_VALUE_V", [])
	_demolition_refund_fraction = float(upgrades.get("DEMOLITION_REFUND_FRACTION", 0.0))
	_repair_cost_per_capital = float(expenses.get("REPAIR_COST_PER_CAPITAL", 0.0))
	_pm_cost_fraction = float(expenses.get("PM_COST_FRACTION", 0.0))
	_pm_min_condition = float(expenses.get("PM_MIN_CONDITION", 0.0))
	_vehicle_resale_fraction = float(expenses.get("VEHICLE_RESALE_FRACTION", 0.0))
	_contractor_surcharge = float(expenses.get("CONTRACTOR_SURCHARGE", 0.0))
	_grid_components = expenses.get("grid_components", {})
	_vehicles = expenses.get("vehicles", {})
	_road_repair_capital_fraction = float(roads.get("ROAD_REPAIR_CAPITAL_FRACTION", 0.0))
	_road_demolish_refund_fraction = float(roads.get("demolish_refund_fraction", 0.0))
	_road_build_cost = roads.get("build_cost_per_tile", {})
	_road_upgrade_cost = roads.get("upgrade_cost_per_tile", {})
	_land_resale_fraction = float(land.get("LAND_RESALE_FRACTION", 0.0))

	if _capital_value_v.size() != LEVELS_PER_ARCHETYPE:
		errors.append("economy.json upgrades.CAPITAL_VALUE_V must carry %d levels"
				% LEVELS_PER_ARCHETYPE)
	if _repair_cost_per_capital <= 0.0:
		errors.append("economy.json expenses.REPAIR_COST_PER_CAPITAL missing")

	_alias = building_economy.get("doc02_archetype_alias", {})
	var archetypes: Dictionary = building_economy.get("archetypes", {})
	if archetypes.is_empty():
		errors.append("building_economy: no archetypes")
	_ids = archetypes.keys()
	_ids.sort()
	for id in _ids:
		var row: Dictionary = archetypes[id]
		_archetypes[String(id)] = row
		for key in REQUIRED_ARCHETYPE_KEYS:
			if not row.has(key):
				errors.append("%s: missing key '%s'" % [id, key])
		_validate_row(String(id), row)


## Re-checks the generator's own contract at load: every generated cell must sit
## within ±$1 of the curve (doc 03 §7 test 8; RR-5 locks three base_tax cells and
## the CAPITAL_VALUE_V vector produces the published capital cells).
func _validate_row(id: String, row: Dictionary) -> void:
	var cost := float(row.get("build_cost_l1", 0))
	var base_tax_l1 := float(row.get("base_tax_l1", 0))
	var taxes: Array = row.get("base_tax_by_level", [])
	var steps: Array = row.get("upgrade_cost_by_step", [])
	var capitals: Array = row.get("capital_value_by_level", [])
	if taxes.size() != LEVELS_PER_ARCHETYPE:
		errors.append("%s: base_tax_by_level must carry %d levels" % [id, LEVELS_PER_ARCHETYPE])
		return
	if capitals.size() != LEVELS_PER_ARCHETYPE:
		errors.append("%s: capital_value_by_level must carry %d levels"
				% [id, LEVELS_PER_ARCHETYPE])
		return
	if steps.size() != LEVELS_PER_ARCHETYPE - 1:
		errors.append("%s: upgrade_cost_by_step must carry %d steps"
				% [id, LEVELS_PER_ARCHETYPE - 1])
		return
	if not REVENUE_CLASSES.has(String(row.get("class", ""))) and base_tax_l1 != 0.0:
		errors.append("%s: civic/utility archetypes carry base_tax 0 (doc 03 §2.2)" % id)
	for level in range(1, LEVELS_PER_ARCHETYPE + 1):
		var expected_tax := round_half_up(base_tax_l1 * pow(_tax_level_growth, level - 1))
		if absi(int(taxes[level - 1]) - expected_tax) > GENERATED_CELL_TOLERANCE:
			errors.append("%s base_tax L%d: %d vs curve %d (>±$%d)"
					% [id, level, int(taxes[level - 1]), expected_tax, GENERATED_CELL_TOLERANCE])
		var expected_capital := round_half_up(cost * float(_capital_value_v[level - 1]))
		if absi(int(capitals[level - 1]) - expected_capital) > GENERATED_CELL_TOLERANCE:
			errors.append("%s capital_value L%d: %d vs curve %d (>±$%d)"
					% [id, level, int(capitals[level - 1]), expected_capital,
					GENERATED_CELL_TOLERANCE])
	for step in range(1, LEVELS_PER_ARCHETYPE):
		var expected_step := round_half_up(cost * _upg_coeff * pow(_upg_growth, step - 1))
		if absi(int(steps[step - 1]) - expected_step) > GENERATED_CELL_TOLERANCE:
			errors.append("%s upgrade_cost step %d: %d vs curve %d (>±$%d)"
					% [id, step, int(steps[step - 1]), expected_step, GENERATED_CELL_TOLERANCE])
