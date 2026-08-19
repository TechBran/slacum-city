class_name WaterData
extends RefCounted
## Typed reader + validator for `data/water.json` (doc 05 §3.1, §8).
##
## The file is the spec; this class only zips `_component_columns` onto
## `components` rows, exposes the tables as typed lookups and enforces the five
## loader assertions doc 05 §3.1 requires:
##   1. every component row length matches its column list;
##   2. no hourly curve lives here (C-33) — doc 01 owns both channels;
##   3. every `demand_split` row sums to 1.000 ± 0.001;
##   4. no key containing cost/price/upkeep/maintenance carries a dollar
##      magnitude (C-07/C-16) — only dimensionless ratios are permitted;
##   5. `components.pump.base_kw` equals doc 02's `water_facility` kW column
##      exactly (C-34/C-35).
## `_provenance` is documentation and is never bound to a runtime field (RR-11).

## Doc 02's amended `water_facility` kW column — the C-34 guard's reference.
const DOC02_PUMP_KW := [60.0, 145.0, 360.0, 880.0, 2160.0]
## Ratio-only keys: a magnitude above this is a dollar figure that escaped C-07.
const RATIO_KEY_MAX := 10.0
const RATIO_KEY_TOKENS := ["cost", "price", "upkeep", "maintenance"]

var errors: PackedStringArray = []

var global_values: Dictionary = {}
var demand_split: Dictionary = {}  # archetype -> {res, com, proc}
var components: Dictionary = {}  # component key -> level(1..5) -> {field: value}
var mains: Dictionary = {}  # tier -> {capacity_m3h, break_rate_mult}
var coverage_frac: Dictionary = {}  # level int -> float
var backup_kw: Dictionary = {}  # component key -> level int -> float
var price_inputs: Dictionary = {}
## §6's MVP placement roster and its shared siting rules. Carries no dollar and
## no capacity — which variant, at which levels, sited how. The placement layer
## reads it exactly as doc 04's reads `data/grid_components.json`.
var placeable: Dictionary = {}
var placement: Dictionary = {}
var failures: Dictionary = {}
var repair: Dictionary = {}
var effects: Dictionary = {}
var contamination: Dictionary = {}
var overlay: Dictionary = {}
var feature_flags: Dictionary = {}
var provenance: Dictionary = {}
var schema_version: int = 0

var _raw: Dictionary = {}


static func from_dict(data: Dictionary) -> WaterData:
	var out := WaterData.new()
	out.load_from(data)
	return out


func is_valid() -> bool:
	return errors.is_empty()


func load_from(data: Dictionary) -> bool:
	errors.clear()
	_raw = data
	schema_version = int(data.get("schema_version", 0))
	global_values = data.get("global", {})
	mains = data.get("mains", {})
	price_inputs = data.get("price_inputs", {})
	placeable = data.get("placeable", {})
	placement = data.get("placement", {})
	failures = data.get("failures", {})
	repair = data.get("repair", {})
	effects = data.get("effects", {})
	contamination = data.get("contamination", {})
	overlay = data.get("overlay", {})
	feature_flags = data.get("feature_flags", {})
	provenance = data.get("_provenance", {})
	_load_demand_split(data.get("demand_split", {}))
	_load_components(data.get("_component_columns", {}), data.get("components", {}))
	_load_backup(data.get("backup", {}))
	_assert_no_hourly_curves(data, "")
	_assert_no_currency(data, "")
	_assert_doc02_kw_column()
	return errors.is_empty()


# ------------------------------------------------------------------ loading

func _load_demand_split(rows: Dictionary) -> void:
	for archetype in _sorted_keys(rows):
		var name := String(archetype)
		if name.begins_with("_"):
			continue
		var row: Variant = rows[archetype]
		if typeof(row) != TYPE_DICTIONARY:
			continue  # `stadium_event_process_mult` and friends
		var res := float(row.get("res", 0.0))
		var com := float(row.get("com", 0.0))
		var proc := float(row.get("proc", 0.0))
		if absf(res + com + proc - 1.0) > 0.001:
			errors.append("demand_split[%s] sums to %f, not 1.000" % [name, res + com + proc])
		demand_split[name] = {"res": res, "com": com, "proc": proc}
	var post_mvp: Dictionary = rows.get("_post_mvp", {})
	for archetype in _sorted_keys(post_mvp):
		var row: Dictionary = post_mvp[archetype]
		var total := float(row.get("res", 0.0)) + float(row.get("com", 0.0)) + float(row.get("proc", 0.0))
		if absf(total - 1.0) > 0.001:
			errors.append("demand_split._post_mvp[%s] sums to %f" % [String(archetype), total])
		demand_split[String(archetype)] = {"res": float(row.get("res", 0.0)),
				"com": float(row.get("com", 0.0)), "proc": float(row.get("proc", 0.0))}


func _load_components(columns: Dictionary, rows: Dictionary) -> void:
	for key in _sorted_keys(rows):
		var component_key := String(key)
		if not columns.has(component_key):
			errors.append("components.%s has no _component_columns entry" % component_key)
			continue
		var column_names: Array = columns[component_key]
		var levels: Dictionary = {}
		var table: Array = rows[key]
		if table.size() != 5:
			errors.append("components.%s has %d levels, expected 5" % [component_key, table.size()])
		for row in table:
			var values: Array = row
			if values.size() != column_names.size():
				errors.append("components.%s row length %d != %d columns"
						% [component_key, values.size(), column_names.size()])
				continue
			var record: Dictionary = {}
			for i in column_names.size():
				record[String(column_names[i])] = values[i]
			levels[int(record.get("level", 0))] = record
		components[component_key] = levels


func _load_backup(backup: Dictionary) -> void:
	for level_key in _sorted_keys(backup.get("coverage_frac", {})):
		coverage_frac[int(String(level_key))] = float(backup["coverage_frac"][level_key])
	for component_key in _sorted_keys(backup.get("backup_kw", {})):
		var per_level: Dictionary = {}
		var rows: Dictionary = backup["backup_kw"][component_key]
		for level_key in _sorted_keys(rows):
			per_level[int(String(level_key))] = float(rows[level_key])
		backup_kw[String(component_key)] = per_level


# --------------------------------------------------------------- assertions

## C-33: the diurnal store is `data/time.json`. No 24-entry array, no `*_hourly`
## key may exist anywhere in this file.
func _assert_no_hourly_curves(value: Variant, path: String) -> void:
	match typeof(value):
		TYPE_DICTIONARY:
			for key in _sorted_keys(value):
				var name := String(key)
				if name.ends_with("_hourly") or name.ends_with("_hours_24"):
					errors.append("C-33: hourly curve key %s/%s — doc 01 owns the curves" % [path, name])
				_assert_no_hourly_curves(value[key], path + "/" + name)
		TYPE_ARRAY:
			var array: Array = value
			if array.size() == 24 and _all_numeric(array):
				errors.append("C-33: 24-entry numeric array at %s — doc 01 owns the curves" % path)
			for i in array.size():
				_assert_no_hourly_curves(array[i], "%s[%d]" % [path, i])
		_:
			pass


## C-07 / C-16: doc 03 is the sole currency authority. A cost/price/upkeep/
## maintenance key may carry a dimensionless ratio and nothing larger.
func _assert_no_currency(value: Variant, path: String) -> void:
	match typeof(value):
		TYPE_DICTIONARY:
			for key in _sorted_keys(value):
				var name := String(key)
				var child_path := path + "/" + name
				if not name.begins_with("_") and _is_ratio_key(name):
					_assert_ratio_magnitudes(value[key], child_path)
				_assert_no_currency(value[key], child_path)
		TYPE_ARRAY:
			for i in (value as Array).size():
				_assert_no_currency(value[i], "%s[%d]" % [path, i])
		_:
			pass


func _assert_ratio_magnitudes(value: Variant, path: String) -> void:
	match typeof(value):
		TYPE_INT, TYPE_FLOAT:
			if absf(float(value)) > RATIO_KEY_MAX:
				errors.append("C-07: %s = %s is a currency magnitude, not a ratio" % [path, str(value)])
		TYPE_DICTIONARY:
			for key in _sorted_keys(value):
				_assert_ratio_magnitudes(value[key], path + "/" + String(key))
		TYPE_ARRAY:
			for i in (value as Array).size():
				_assert_ratio_magnitudes(value[i], "%s[%d]" % [path, i])
		_:
			pass


## C-34/C-35: the pump ladder IS doc 02's `water_facility` kW column.
func _assert_doc02_kw_column() -> void:
	for level in range(1, 6):
		var record: Dictionary = components.get("pump", {}).get(level, {})
		if record.is_empty():
			errors.append("components.pump has no level %d" % level)
			continue
		if absf(float(record.get("base_kw", 0.0)) - DOC02_PUMP_KW[level - 1]) > 0.0001:
			errors.append("C-34: components.pump[%d].base_kw = %s, doc 02 says %s"
					% [level, str(record.get("base_kw")), str(DOC02_PUMP_KW[level - 1])])


static func _is_ratio_key(name: String) -> bool:
	var lower := name.to_lower()
	for token in RATIO_KEY_TOKENS:
		if lower.contains(token):
			return true
	return false


static func _all_numeric(array: Array) -> bool:
	for entry in array:
		if typeof(entry) != TYPE_INT and typeof(entry) != TYPE_FLOAT:
			return false
	return true


# ------------------------------------------------------------------ queries

## `source` splits into `source_river` / `source_well` component keys (§8).
static func component_key(variant: StringName, subtype: String = "") -> String:
	if variant == &"source":
		return "source_well" if subtype == "well" else "source_river"
	return String(variant)


func component(variant: StringName, level: int, subtype: String = "") -> Dictionary:
	return components.get(component_key(variant, subtype), {}).get(clampi(level, 1, 5), {})


func global_value(key: String, fallback: float = 0.0) -> float:
	return float(global_values.get(key, fallback))


func effect(key: String, fallback: float = 0.0) -> float:
	return float(effects.get(key, fallback))


func failure_value(key: String, fallback: float = 0.0) -> float:
	return float(failures.get(key, fallback))


func base_failure_rate(kind: String) -> float:
	return float(failures.get("base_rate_per_hour", {}).get(kind, 0.0))


func freeze_value(key: String, fallback: float = 0.0) -> float:
	return float(failures.get("freeze", {}).get(key, fallback))


func condition_decay_per_hour(kind: String) -> float:
	return float(failures.get("condition_decay_per_hour", {}).get(kind, 0.0))


func weather_failure_mult(kind: String) -> float:
	return float(failures.get("weather_failure_mult", {}).get(kind, 1.0))


func repair_base_minutes(kind: String) -> float:
	return float(repair.get("base_minutes", {}).get(kind, 0.0))


func repair_post_condition(kind: String) -> float:
	return float(repair.get("post_repair_condition", {}).get(kind, 0.85))


func crew_mult(vehicle: String) -> float:
	return float(repair.get("crew_mult", {}).get(vehicle, 1.0))


func main_capacity(tier: String) -> float:
	return float(mains.get(tier, {}).get("capacity_m3h", 0.0))


func main_break_rate_mult(tier: String) -> float:
	return float(mains.get(tier, {}).get("break_rate_mult", 1.0))


func split_for(archetype: String) -> Dictionary:
	return demand_split.get(archetype, {"res": 0.0, "com": 0.0, "proc": 1.0})


func coverage_frac_for(level: int) -> float:
	return float(coverage_frac.get(clampi(level, 1, 5), 0.0))


## Published to doc 04 as the generator sizing input (C-36).
func backup_kw_for(variant: StringName, level: int, subtype: String = "") -> float:
	return float(backup_kw.get(component_key(variant, subtype), {}).get(clampi(level, 1, 5), 0.0))


## Published to doc 04 as the sink rating (C-36).
func kw_required(variant: StringName, level: int, subtype: String = "") -> float:
	return float(component(variant, level, subtype).get("base_kw", 0.0))


func flag(name: String) -> bool:
	return bool(feature_flags.get(name, false))


## §6 placement roster: the rules for one variant, `{}` when it is not placeable.
func placeable_rules(variant: String) -> Dictionary:
	var row: Variant = placeable.get(variant, {})
	return row if row is Dictionary else {}


func placeable_variants() -> Array:
	var out: Array = []
	for key in placeable:
		if not String(key).begins_with("_"):
			out.append(String(key))
	out.sort()
	return out


func placement_value(key: String, fallback: Variant) -> Variant:
	return placement.get(key, fallback)


## Doc 05 §2.1: a variant's footprint at a level, from the component table (doc
## 02's `per_variant_footprint_source` points here, so nothing is duplicated).
func footprint_of(variant: StringName, level: int, subtype: String = "") -> Vector2i:
	var row := component(variant, level, subtype)
	return Vector2i(int(row.get("footprint_w", 1)), int(row.get("footprint_h", 1)))


## The dimensionless L1 cost ratio doc 03 multiplies its `water_plant` anchor by.
func variant_cost_ratio(variant: StringName, subtype: String = "") -> float:
	var ratios: Dictionary = price_inputs.get("variant_cost_ratio_l1", {})
	return float(ratios.get(component_key(variant, subtype), 0.0))


func main_cost_ratio(tier: String) -> float:
	var ratios: Dictionary = price_inputs.get("main_cost_ratio_per_tile", {})
	return float(ratios.get(tier, 0.0))


func raw() -> Dictionary:
	return _raw


static func _sorted_keys(dict: Dictionary) -> Array:
	var keys := dict.keys()
	keys.sort()
	return keys
