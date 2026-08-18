class_name BuildingCatalog
extends RefCounted
## Read-only lookup over `data/buildings.json` + `data/building_rules.json`
## (doc 02 §3.1 / §8). Pure: no state, no tick, no file IO in the constructor —
## the parsed Dictionaries are handed in, so the catalog is testable from
## fixtures. `load_from_files()` is the only path that touches FileAccess.
##
## Every loader invariant of doc 02 §3.1 is checked at construction and the
## failures are collected in `errors` rather than raised, mirroring DayCurveSet.
##
## The tables themselves are GENERATED — `tools/gen_buildings.py` grows all 60
## rows from `building_rules.json`'s normative `seed_rows` (report 98 RR-8).
## Nothing here recomputes a curve; the ladders are table-generation-time only.

const LEVELS_PER_ARCHETYPE := 5  # Core Design Rule 5
const ARCHETYPE_COUNT := 12  # spec §43.2 MVP roster
const DECAY_SCALE_GUARD := 0.01  # doc 02 §3.1: fails loudly on the old [0,100] scale
const WATER_ARCHETYPE := "water_facility"

const CATEGORIES := ["residential", "commercial", "industrial", "service", "utility"]
const TAX_CLASSES := ["residential", "commercial", "industrial", "tech", "civic", "utility"]

## Doc 02 §3.1 — deleted by report 98; reintroducing one is a schema violation.
const FORBIDDEN_KEYS := [
	"build_cost", "upgrade_cost", "tax_cents_per_hour", "upkeep_cents_per_hour",
	"power_supply_kw", "power_throughput_kw", "feeder_radius_tiles",
	"water_supply_wu_per_hour", "pressure_radius_tiles", "unit_slots", "crew_slots",
	"burn_hours", "condition_loss_per_hour", "required_fire_units", "spread_radius_tiles",
]

## Doc 02 §2.3 columns that must exist on every one of the 60 rows.
const REQUIRED_LEVEL_KEYS := [
	"level", "footprint", "population", "jobs", "power_demand_kw", "water_demand",
	"build_time_hours", "decay_per_hour", "fire_ignition_per_hour", "fire_load",
	"crime_weight", "req_fire_coverage", "req_police_coverage", "min_city_level",
]

const INT_LEVEL_KEYS := [
	"level", "population", "jobs", "fire_load", "min_city_level", "coverage_radius_tiles",
]
const FLOAT_LEVEL_KEYS := [
	"power_demand_kw", "water_demand", "build_time_hours", "upgrade_time_hours",
	"decay_per_hour", "fire_ignition_per_hour", "crime_weight",
	"req_fire_coverage", "req_police_coverage",
]

## Doc 02 §7 test 5 asks that "every condition constant in building_rules.json
## ∈ [0,1]". Read literally that fails on §8's own block, which also stores rate
## multipliers and coefficients under `condition` — `damaged_decay_multiplier`
## is 1.50. The invariant that C-14 actually installed is that every constant
## expressed ON the condition scale is on [0,1]; those keys are named here.
const CONDITION_SCALE_KEYS := [
	"start", "band_good", "band_worn", "band_poor", "auto_damage_threshold",
	"structural_failure_threshold", "structural_failure_p_per_hour",
	"offline_burn_down_clamp", "repair_target_active", "repair_target_damaged",
	"min_condition_to_upgrade",
]

## Doc 02 §8 blocks `building_rules.json` must carry.
const REQUIRED_RULE_KEYS := [
	"schema_version", "growth_classes", "demand_growth_invariant", "shared_curves",
	"water_facility_variants", "water_facility_reference_variant", "coverage_ladder",
	"min_city_level_by_level", "safety_coverage_factor", "condition", "fire",
	"construction", "headroom_safety", "avenue_gate", "state_modifiers",
	"seed_rows", "rounding",
]

var errors: PackedStringArray = []

var _archetypes: Dictionary = {}  # id -> {name, category, tax_class, growth_class, produces, ...}
var _levels: Dictionary = {}  # id -> Array[Dictionary], index 0 == level 1
var _rules: Dictionary = {}
var _ids: Array = []
var _levels_per_archetype: int = LEVELS_PER_ARCHETYPE
var _schema_version: int = 0


func _init(buildings_data: Dictionary, rules_data: Dictionary) -> void:
	_load(buildings_data, rules_data)


## Convenience for the running game; tests build from fixtures instead.
static func load_from_files(
		buildings_path: String = "res://data/buildings.json",
		rules_path: String = "res://data/building_rules.json") -> BuildingCatalog:
	var buildings: Variant = JSON.parse_string(FileAccess.get_file_as_string(buildings_path))
	var rules: Variant = JSON.parse_string(FileAccess.get_file_as_string(rules_path))
	var catalog := BuildingCatalog.new(
			buildings if buildings is Dictionary else {},
			rules if rules is Dictionary else {})
	if not (buildings is Dictionary):
		catalog.errors.append("cannot parse %s" % buildings_path)
	if not (rules is Dictionary):
		catalog.errors.append("cannot parse %s" % rules_path)
	return catalog


func is_valid() -> bool:
	return errors.is_empty()


func schema_version() -> int:
	return _schema_version


## Sorted archetype ids.
func archetypes() -> Array:
	return _ids.duplicate()


func has(archetype: String) -> bool:
	return _archetypes.has(archetype)


func max_level() -> int:
	return _levels_per_archetype


## The doc 02 §2.3 row for one archetype at one level (1-based). Read-only;
## returns an empty Dictionary for an unknown archetype or an out-of-range level.
func stats(archetype: String, level: int) -> Dictionary:
	if not _levels.has(archetype):
		return {}
	var rows: Array = _levels[archetype]
	if level < 1 or level > rows.size():
		return {}
	return rows[level - 1]


## All five rows for one archetype, ascending. Read-only.
func levels(archetype: String) -> Array:
	return _levels.get(archetype, [])


## Non-per-level metadata: name, category, tax_class, growth_class, produces,
## and (water_facility only) variants + reference_variant. Read-only.
func archetype_info(archetype: String) -> Dictionary:
	return _archetypes.get(archetype, {})


func growth_class(archetype: String) -> String:
	return String(_archetypes.get(archetype, {}).get("growth_class", ""))


func tax_class(archetype: String) -> String:
	return String(_archetypes.get(archetype, {}).get("tax_class", ""))


func category(archetype: String) -> String:
	return String(_archetypes.get(archetype, {}).get("category", ""))


## Doc 02 §8 `building_rules.json`, whole. Read-only.
func rules() -> Dictionary:
	return _rules


## The five `water_facility` node kinds (doc 02 §2.1, C-35), in doc order.
func water_variants() -> Array:
	return _rules.get("water_facility_variants", []).duplicate()


## The variant the §2.3 shell table — including its `footprint` column — is
## generated for (report 98 RR-8).
func reference_water_variant() -> String:
	return String(_rules.get("water_facility_reference_variant", ""))


func is_water_variant(variant: String) -> bool:
	return water_variants().has(variant)


## Report 98 RR-8 / doc 02 §3.1: `water_facility.levels[*].footprint` is the
## `pump` reference row and must equal doc 05's `components.pump` footprints.
## Doc 05's `data/water.json` does not exist yet, so this is a separate call the
## boot sequence makes once that file lands, not a constructor invariant.
func cross_check_water_footprints(water_data: Dictionary) -> PackedStringArray:
	var problems := PackedStringArray()
	var reference := reference_water_variant()
	var components: Dictionary = water_data.get("components", {})
	if not components.has(reference):
		problems.append("data/water.json has no components.%s to cross-check" % reference)
		return problems
	var per_level: Array = components[reference]
	if per_level.size() != _levels_per_archetype:
		problems.append("data/water.json components.%s has %d levels, expected %d"
				% [reference, per_level.size(), _levels_per_archetype])
		return problems
	for i in per_level.size():
		var theirs: Dictionary = per_level[i]
		var ours: Array = stats(WATER_ARCHETYPE, i + 1).get("footprint", [])
		var w := int(theirs.get("footprint_w", -1))
		var h := int(theirs.get("footprint_h", -1))
		if ours.size() != 2 or ours[0] != w or ours[1] != h:
			problems.append("water_facility L%d footprint %s != doc 05 components.%s [%d, %d]"
					% [i + 1, str(ours), reference, w, h])
	return problems


# --------------------------------------------------------------------------
# Loading & validation (doc 02 §3.1)
# --------------------------------------------------------------------------

func _load(buildings_data: Dictionary, rules_data: Dictionary) -> void:
	errors.clear()
	_archetypes.clear()
	_levels.clear()
	_rules = {}
	_ids = []

	_load_rules(rules_data)

	if not buildings_data.has("schema_version"):
		errors.append("buildings: missing schema_version")
	else:
		_schema_version = int(buildings_data["schema_version"])
		if _schema_version < 1:
			errors.append("buildings: schema_version %d must be >= 1" % _schema_version)

	var meta: Dictionary = buildings_data.get("generated", {})
	if meta.has("levels_per_archetype"):
		_levels_per_archetype = int(meta["levels_per_archetype"])
	if _levels_per_archetype != LEVELS_PER_ARCHETYPE:
		errors.append("buildings: levels_per_archetype %d, Core Rule 5 requires %d"
				% [_levels_per_archetype, LEVELS_PER_ARCHETYPE])
		_levels_per_archetype = LEVELS_PER_ARCHETYPE

	var raw: Dictionary = buildings_data.get("archetypes", {})
	if raw.is_empty():
		errors.append("buildings: no archetypes")
		return
	if raw.size() != ARCHETYPE_COUNT:
		errors.append("buildings: %d archetypes, spec §43.2 requires %d"
				% [raw.size(), ARCHETYPE_COUNT])

	var ids: Array = raw.keys()
	ids.sort()
	for id_variant in ids:
		var archetype := String(id_variant)
		var entry: Variant = raw[id_variant]
		if not (entry is Dictionary):
			errors.append("%s: archetype entry is not an object" % archetype)
			continue
		_load_archetype(archetype, entry)
	_ids = _levels.keys()
	_ids.sort()


func _load_archetype(archetype: String, entry: Dictionary) -> void:
	for key in FORBIDDEN_KEYS:
		if entry.has(key):
			errors.append("%s: forbidden field '%s' (deleted by report 98)" % [archetype, key])

	var info := {
		"name": String(entry.get("name", "")),
		"category": String(entry.get("category", "")),
		"tax_class": String(entry.get("tax_class", "")),
		"growth_class": String(entry.get("growth_class", "")),
		"produces": entry.get("produces", []),
	}
	if String(info["name"]).is_empty():
		errors.append("%s: missing name" % archetype)
	if not CATEGORIES.has(info["category"]):
		errors.append("%s: bad category '%s'" % [archetype, info["category"]])
	if not TAX_CLASSES.has(info["tax_class"]):
		errors.append("%s: bad tax_class '%s'" % [archetype, info["tax_class"]])
	var growth_classes: Dictionary = _rules.get("growth_classes", {})
	if not growth_classes.has(info["growth_class"]):
		errors.append("%s: growth_class '%s' is not in building_rules.growth_classes"
				% [archetype, info["growth_class"]])
	if not (info["produces"] is Array) or (info["produces"] as Array).is_empty():
		errors.append("%s: produces must be a non-empty array" % archetype)
	else:
		var produces: Array = (info["produces"] as Array).duplicate()
		produces.make_read_only()
		info["produces"] = produces

	# `variants` present iff water_facility (report 98 C-35 / RR-8).
	var has_variants := entry.has("variants")
	if has_variants != (archetype == WATER_ARCHETYPE):
		errors.append("%s: 'variants' must be present iff id == '%s'"
				% [archetype, WATER_ARCHETYPE])
	if has_variants:
		var variants: Array = entry.get("variants", [])
		if variants != _rules.get("water_facility_variants", []):
			errors.append("%s: variants %s disagree with building_rules.water_facility_variants %s"
					% [archetype, str(variants), str(_rules.get("water_facility_variants", []))])
		info["variants"] = variants.duplicate()
		info["reference_variant"] = String(entry.get("reference_variant", ""))
		if not variants.has(info["reference_variant"]):
			errors.append("%s: reference_variant '%s' is not one of the variants"
					% [archetype, info["reference_variant"]])
		if not bool(entry.get("footprints_are_reference_variant_only", false)):
			errors.append("%s: footprints_are_reference_variant_only must be true (RR-8)"
					% archetype)

	var rows: Variant = entry.get("levels", [])
	if not (rows is Array) or (rows as Array).size() != _levels_per_archetype:
		errors.append("%s: expected %d levels, got %s"
				% [archetype, _levels_per_archetype,
				str((rows as Array).size()) if rows is Array else "non-array"])
		return

	var seed_row: Dictionary = _rules.get("seed_rows", {}).get(archetype, {})
	var wants_radius := seed_row.has("coverage_radius")
	var parsed: Array = []
	var previous := {}
	for index in (rows as Array).size():
		var level_no := index + 1
		var row: Variant = rows[index]
		if not (row is Dictionary):
			errors.append("%s L%d: level entry is not an object" % [archetype, level_no])
			return
		var clean := _load_level(archetype, level_no, row, wants_radius)
		if not previous.is_empty():
			_check_monotonic(archetype, level_no, previous, clean)
		previous = clean
		clean.make_read_only()
		parsed.append(clean)
	parsed.make_read_only()

	info.make_read_only()
	_archetypes[archetype] = info
	_levels[archetype] = parsed


func _load_level(archetype: String, level_no: int, row: Dictionary,
		wants_radius: bool) -> Dictionary:
	var clean := {}
	for key in FORBIDDEN_KEYS:
		if row.has(key):
			errors.append("%s L%d: forbidden column '%s' (deleted by report 98)"
					% [archetype, level_no, key])
	for key in REQUIRED_LEVEL_KEYS:
		if not row.has(key):
			errors.append("%s L%d: missing column '%s'" % [archetype, level_no, key])

	# Godot's JSON parser hands every number back as a float — cast on read.
	for key in INT_LEVEL_KEYS:
		if not row.has(key):
			continue
		var raw_value := float(row[key])
		var as_int := int(roundf(raw_value))
		if absf(raw_value - float(as_int)) > 0.0:
			errors.append("%s L%d: '%s' = %s is not an integer"
					% [archetype, level_no, key, str(row[key])])
		if as_int < 0:
			errors.append("%s L%d: '%s' = %d must be >= 0" % [archetype, level_no, key, as_int])
		clean[key] = as_int
	for key in FLOAT_LEVEL_KEYS:
		if not row.has(key):
			continue
		var value := float(row[key])
		if value < 0.0:
			errors.append("%s L%d: '%s' = %f must be >= 0" % [archetype, level_no, key, value])
		clean[key] = value

	if int(clean.get("level", -1)) != level_no:
		errors.append("%s: levels out of order — index %d carries level %s"
				% [archetype, level_no, str(clean.get("level", "missing"))])
		clean["level"] = level_no

	var footprint: Variant = row.get("footprint", [])
	if not (footprint is Array) or (footprint as Array).size() != 2:
		errors.append("%s L%d: footprint must be [w, h]" % [archetype, level_no])
		clean["footprint"] = [1, 1]
	else:
		var w := int(roundf(float(footprint[0])))
		var h := int(roundf(float(footprint[1])))
		if w < 1 or h < 1:
			errors.append("%s L%d: footprint %dx%d must be at least 1x1"
					% [archetype, level_no, w, h])
		var size := [w, h]
		size.make_read_only()
		clean["footprint"] = size

	# `upgrade_time_hours` present on 1..4, absent on 5 (doc 02 §3.1).
	var is_top := level_no == _levels_per_archetype
	var has_upgrade := row.has("upgrade_time_hours")
	if has_upgrade == is_top:
		errors.append("%s L%d: upgrade_time_hours must be %s"
				% [archetype, level_no, "absent at the top level" if is_top else "present"])

	# `coverage_radius_tiles` only where doc 02 §2.4 publishes a reach column.
	if row.has("coverage_radius_tiles") != wants_radius:
		errors.append("%s L%d: coverage_radius_tiles must be %s (doc 02 §2.4)"
				% [archetype, level_no, "present" if wants_radius else "absent"])

	var decay := float(clean.get("decay_per_hour", 0.0))
	if decay >= DECAY_SCALE_GUARD:
		errors.append("%s L%d: decay_per_hour %f is not on the [0,1] scale (C-14)"
				% [archetype, level_no, decay])

	var max_requirement := float(_rules.get("coverage_ladder", {}).get("max_requirement", 1.0))
	for key in ["req_fire_coverage", "req_police_coverage"]:
		var requirement := float(clean.get(key, 0.0))
		if requirement > max_requirement:
			errors.append("%s L%d: %s %f exceeds max_requirement %f"
					% [archetype, level_no, key, requirement, max_requirement])
	return clean


func _check_monotonic(archetype: String, level_no: int, previous: Dictionary,
		current: Dictionary) -> void:
	var before: Array = previous.get("footprint", [1, 1])
	var after: Array = current.get("footprint", [1, 1])
	if after[0] < before[0] or after[1] < before[1]:
		errors.append("%s L%d: footprint %s shrinks from %s"
				% [archetype, level_no, str(after), str(before)])
	if int(current.get("min_city_level", 0)) < int(previous.get("min_city_level", 0)):
		errors.append("%s L%d: min_city_level %d decreases from %d"
				% [archetype, level_no, int(current.get("min_city_level", 0)),
				int(previous.get("min_city_level", 0))])


func _load_rules(rules_data: Dictionary) -> void:
	_rules = rules_data
	for key in REQUIRED_RULE_KEYS:
		if not rules_data.has(key):
			errors.append("building_rules: missing block '%s'" % key)
	if rules_data.is_empty():
		return

	var growth_classes: Dictionary = rules_data.get("growth_classes", {})
	if growth_classes.is_empty():
		errors.append("building_rules: growth_classes is empty")
	# C-13 / spec §55 rule 3: every class must out-grow doc 03's TAX_LEVEL_GROWTH.
	var invariant: Dictionary = rules_data.get("demand_growth_invariant", {})
	var must_exceed := float(invariant.get("must_exceed_value", 0.0))
	if must_exceed <= 0.0:
		errors.append("building_rules: demand_growth_invariant.must_exceed_value missing")
	for name_variant in growth_classes:
		var growth: Dictionary = growth_classes[name_variant]
		for k in ["k_out", "k_dem", "k_time"]:
			if not growth.has(k):
				errors.append("building_rules: growth class %s missing %s" % [name_variant, k])
		if float(growth.get("k_dem", 0.0)) <= must_exceed:
			errors.append("building_rules: growth class %s has k_dem %f <= %f (report 98 C-13)"
					% [name_variant, float(growth.get("k_dem", 0.0)), must_exceed])

	var variants: Array = rules_data.get("water_facility_variants", [])
	if variants.is_empty():
		errors.append("building_rules: water_facility_variants is empty")
	elif not variants.has(String(rules_data.get("water_facility_reference_variant", ""))):
		errors.append("building_rules: water_facility_reference_variant is not in the variant list")

	# Doc 02 §7 test 5 / C-14: the condition scale is [0,1] everywhere.
	var condition: Dictionary = rules_data.get("condition", {})
	for key in condition:
		var value := float(condition[key])
		if value < 0.0:
			errors.append("building_rules: condition.%s = %f must be >= 0" % [key, value])
		elif value > 1.0 and CONDITION_SCALE_KEYS.has(String(key)):
			errors.append("building_rules: condition.%s = %f is outside [0,1] (C-14)"
					% [key, value])
	for key in CONDITION_SCALE_KEYS:
		if not condition.has(key):
			errors.append("building_rules: condition block missing '%s'" % key)

	var states: Dictionary = rules_data.get("state_modifiers", {})
	for state_variant in states:
		var modifiers: Dictionary = states[state_variant]
		for key in ["output", "demand", "occupancy", "coverage"]:
			if not modifiers.has(key):
				errors.append("building_rules: state_modifiers.%s missing '%s'"
						% [state_variant, key])
