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
## The tables themselves are GENERATED — `tools/gen_buildings.py` grows all 66
## rows from `building_rules.json`'s normative `seed_rows` (report 98 RR-8).
## Nothing here recomputes a curve; the ladders are table-generation-time only.
##
## **The ladder is not the same height for every archetype** (doc 02 §2.14, doc
## 92 §24). Core Design Rule 5 read "five levels each"; it now reads *five for
## every archetype, six for the growth stock* — the six revenue-producing
## archetypes `building_rules.sixth_level_archetypes` names. The other six stop
## at five because their level ladders are not doc 02's alone: `water_facility`
## is doc 05's per-variant component table and the two stations are doc 06's
## `capacity_per_station_level`, and both of those publish five rows. So
## [max_level] is the tallest ladder in the roster and [max_level_of] is the one
## a caller holding an archetype actually wants; asking the wrong one is how a
## build panel offers a police station a sixth rung that does not exist.

const LEVELS_PER_ARCHETYPE := 5  # the floor: every archetype has at least these
const TOP_LEVELS_PER_ARCHETYPE := 6  # the ceiling: the growth stock's sixth rung
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

## Doc 02 §2.3 columns that must exist on every one of the 66 rows.
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
	"min_city_level_by_level", "sixth_level_archetypes", "safety_coverage_factor",
	"condition", "fire", "construction", "headroom_safety", "avenue_gate",
	"state_modifiers", "seed_rows", "rounding",
]

var errors: PackedStringArray = []

var _archetypes: Dictionary = {}  # id -> {name, category, tax_class, growth_class, produces, ...}
var _levels: Dictionary = {}  # id -> Array[Dictionary], index 0 == level 1
var _rules: Dictionary = {}
var _ids: Array = []
## archetype -> how many rows its ladder has. Declared by the generated file's
## `generated.levels_by_archetype`; an archetype the map does not name falls back
## to the five-rung floor, which is the shape every archetype had before doc 92
## §24 and is therefore the safe degrade.
var _levels_by_archetype: Dictionary = {}
var _top_levels: int = LEVELS_PER_ARCHETYPE
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


## The tallest ladder in the roster. This is the right question for a display
## that has to size a level strip once, and the WRONG one for "may this building
## upgrade?" — that is [max_level_of].
func max_level() -> int:
	return _top_levels


## How many rungs `archetype`'s own ladder has (doc 02 §2.14). An unknown
## archetype answers the five-rung floor rather than 0, so a caller that already
## failed to find the archetype does not also divide by zero.
func max_level_of(archetype: String) -> int:
	var rows: Array = _levels.get(archetype, [])
	return rows.size() if not rows.is_empty() else LEVELS_PER_ARCHETYPE


## True when `archetype` is at the top of its own ladder at `level`.
func is_top_level(archetype: String, level: int) -> bool:
	return level >= max_level_of(archetype)


## The doc 02 §2.3 row for one archetype at one level (1-based). Read-only;
## returns an empty Dictionary for an unknown archetype or an out-of-range level.
func stats(archetype: String, level: int) -> Dictionary:
	if not _levels.has(archetype):
		return {}
	var rows: Array = _levels[archetype]
	if level < 1 or level > rows.size():
		return {}
	return rows[level - 1]


## Every row for one archetype, ascending — five, or six for the growth stock.
## Read-only.
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


## Doc 02 §2.6's condition block, the dictionary `Building` is stamped with
## (PA-13, doc 93 §Y2). Returned by reference on purpose: every `Building` in a
## city shares this one instance, so the stamp costs a reference and no copy.
## Empty when a fixture's rules carry no block, and `Building` then falls back to
## its own `DEFAULT_CONDITION`, which is bit-identical to the pre-Wave-17 consts.
func condition_rules() -> Dictionary:
	return _rules.get("condition", {})


## Doc 02 §2.6a's owner-maintenance rule (doc 93 §Y1): is this archetype PRIVATE
## STOCK, kept up by its owner rather than by the city's crews? Decided by tax
## class — `building_rules.owner_maintenance.classes` names them — so a fixture
## whose rules carry no block answers false for everything and keeps the
## pre-Wave-17 behaviour exactly.
func owner_maintained(archetype: String) -> bool:
	var block: Dictionary = _rules.get("owner_maintenance", {})
	return (block.get("classes", []) as Array).has(tax_class(archetype))


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
	var want := max_level_of(WATER_ARCHETYPE)
	if per_level.size() != want:
		problems.append("data/water.json components.%s has %d levels, expected %d"
				% [reference, per_level.size(), want])
		return problems
	# Doc 05 §3.1 ships `components` as COLUMN-ORDERED rows zipped through
	# `_component_columns`; a plain {footprint_w, footprint_h} row is also
	# accepted so a hand-written fixture stays readable.
	var columns: Array = water_data.get("_component_columns", {}).get(reference, [])
	for i in per_level.size():
		var theirs: Dictionary = _as_component_row(per_level[i], columns)
		var ours: Array = stats(WATER_ARCHETYPE, i + 1).get("footprint", [])
		var w := int(theirs.get("footprint_w", -1))
		var h := int(theirs.get("footprint_h", -1))
		if ours.size() != 2 or ours[0] != w or ours[1] != h:
			problems.append("water_facility L%d footprint %s != doc 05 components.%s [%d, %d]"
					% [i + 1, str(ours), reference, w, h])
	return problems


static func _as_component_row(row: Variant, columns: Array) -> Dictionary:
	if row is Dictionary:
		return row
	var values: Array = row
	var out: Dictionary = {}
	for i in mini(values.size(), columns.size()):
		out[String(columns[i])] = values[i]
	return out


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
	var floor_levels := int(meta.get("levels_per_archetype", LEVELS_PER_ARCHETYPE))
	if floor_levels != LEVELS_PER_ARCHETYPE:
		errors.append("buildings: levels_per_archetype %d, the floor is %d"
				% [floor_levels, LEVELS_PER_ARCHETYPE])
	_top_levels = int(meta.get("top_levels_per_archetype", LEVELS_PER_ARCHETYPE))
	if _top_levels < LEVELS_PER_ARCHETYPE or _top_levels > TOP_LEVELS_PER_ARCHETYPE:
		errors.append("buildings: top_levels_per_archetype %d is outside [%d, %d]"
				% [_top_levels, LEVELS_PER_ARCHETYPE, TOP_LEVELS_PER_ARCHETYPE])
		_top_levels = LEVELS_PER_ARCHETYPE
	_levels_by_archetype = meta.get("levels_by_archetype", {})

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

	# How tall this archetype's ladder is DECLARED to be, and the two invariants
	# that make the declaration trustworthy: it is inside [5, 6], and the sixth
	# rung exists exactly where `building_rules.sixth_level_archetypes` says.
	var declared := int(_levels_by_archetype.get(archetype, LEVELS_PER_ARCHETYPE))
	var sixth: Array = _rules.get("sixth_level_archetypes", [])
	var wants_sixth := sixth.has(archetype)
	if declared != (TOP_LEVELS_PER_ARCHETYPE if wants_sixth else LEVELS_PER_ARCHETYPE):
		errors.append("%s: levels_by_archetype says %d, sixth_level_archetypes says %s"
				% [archetype, declared, "6" if wants_sixth else "5"])
		declared = TOP_LEVELS_PER_ARCHETYPE if wants_sixth else LEVELS_PER_ARCHETYPE
	if declared > _top_levels:
		errors.append("%s: %d levels exceeds top_levels_per_archetype %d"
				% [archetype, declared, _top_levels])

	var rows: Variant = entry.get("levels", [])
	if not (rows is Array) or (rows as Array).size() != declared:
		errors.append("%s: expected %d levels, got %s"
				% [archetype, declared,
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
		var clean := _load_level(archetype, level_no, row, wants_radius, declared)
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
		wants_radius: bool, top_level: int) -> Dictionary:
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

	# `upgrade_time_hours` present on every rung but this archetype's LAST one
	# (doc 02 §3.1). The last one is 5 or 6 depending on the ladder, so the check
	# is against the archetype's own height and never against a constant.
	var is_top := level_no == top_level
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

	# Doc 02 §2.6a (doc 93 §Y1): the owner-maintenance block is optional for a
	# fixture and validated when present. It authors NO number — only the tax
	# classes whose stock keeps itself up — so the one thing to check is that
	# every class it names is a real one, or the block would silently name
	# nobody and the ruling would be a no-op the loader approved.
	if rules_data.has("owner_maintenance"):
		var owner: Dictionary = rules_data.get("owner_maintenance", {})
		var owner_classes: Array = owner.get("classes", [])
		if owner_classes.is_empty():
			errors.append("building_rules: owner_maintenance.classes is empty")
		for entry in owner_classes:
			if not TAX_CLASSES.has(String(entry)):
				errors.append("building_rules: owner_maintenance.classes names '%s', not a tax class"
						% String(entry))

	var states: Dictionary = rules_data.get("state_modifiers", {})
	for state_variant in states:
		var modifiers: Dictionary = states[state_variant]
		for key in ["output", "demand", "occupancy", "coverage"]:
			if not modifiers.has(key):
				errors.append("building_rules: state_modifiers.%s missing '%s'"
						% [state_variant, key])
