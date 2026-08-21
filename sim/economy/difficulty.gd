class_name Difficulty
extends RefCounted
## Doc 03 §2.9 / §3.4 — **the** difficulty loader. One file, one schema, one
## loader (report 98 C-17; doc 91 A91-D-19 closes the gap between that ruling and
## the tree).
##
## `data/difficulty.json` holds four sections — `economic` (doc 03), `pressure`
## (doc 07), `escalation` (doc 06) and `offline` (doc 08) — each with a row for
## each of the four presets. This class is the ONLY thing that opens that file:
## systems ask it, and nobody parses the table twice.
##
## **The read path is `value(section, key)`, not `get(section, key)`.** §3.4 rule
## 5 names the latter and it cannot ship under that name: `get` is
## `Object.get(StringName) -> Variant`, and GDScript refuses a method that
## redeclares a native one with a different signature. The rule is about there
## being exactly ONE read path, and there is; only the spelling moved.
##
## **A missing row is a load error, never a silent default** (§2.9 rule 1). The
## validation below is the whole reason a fifth doc cannot quietly add a fifth
## scalar: a section that is not in `meta.sections`, a knob that appears on one
## preset and not another, a nested table, or a multiplier whose casual→crisis
## sequence is not monotone in its own declared direction all refuse the file.
##
## Determinism: this class holds no RNG, no clock and no mutable state after
## `select()`. The preset is chosen ONCE, at founding, and a city keeps it for
## life (doc 93 §K1) — so nothing here can move a running city's numbers.

const DATA_PATH := "res://data/difficulty.json"
const SCHEMA_VERSION := 1

## §2.9 rule 1: exactly these four names, in this order.
const PRESETS: Array[String] = ["casual", "standard", "hard", "crisis"]
## §3.4 rule 2: exactly these section keys.
const SECTIONS: Array[String] = ["economic", "pressure", "escalation", "offline"]
## The preset a city is founded on when nothing chooses, and the one every
## number in doc 92 is measured against.
const DEFAULT_PRESET := "standard"

## §3.4 rule 4's pattern: a knob whose name says it is a scale must declare which
## way it scales. Anything else may declare a direction and is then held to it.
const SCALE_PREFIXES: Array[String] = ["M_"]
const SCALE_SUFFIXES: Array[String] = ["_mult", "_fraction"]

var preset: String = DEFAULT_PRESET
var errors: PackedStringArray = []

var _sections: Dictionary = {}     # section -> preset -> {knob: scalar}
var _directions: Dictionary = {}   # section -> {knob: "up"|"down"}
var _default_preset: String = DEFAULT_PRESET


static func load_from_file(path: String = DATA_PATH) -> Difficulty:
	var out := Difficulty.new()
	if not FileAccess.file_exists(path):
		out.errors.append("difficulty data missing: " + path)
		return out
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		out.errors.append("difficulty data is not a JSON object: " + path)
		return out
	out.load_from(parsed)
	return out


func load_from(data: Dictionary) -> bool:
	errors.clear()
	_sections.clear()
	_directions.clear()
	var meta: Dictionary = data.get("meta", {}) if data.get("meta") is Dictionary else {}
	if int(meta.get("schema_version", -1)) != SCHEMA_VERSION:
		errors.append("difficulty.json schema_version must be %d" % SCHEMA_VERSION)
		return false
	_check_presets(meta)
	_check_sections(meta, data)
	_default_preset = String(meta.get("default_preset", DEFAULT_PRESET))
	if not PRESETS.has(_default_preset):
		errors.append("meta.default_preset %s is not a preset" % _default_preset)
		_default_preset = DEFAULT_PRESET
	for section in SECTIONS:
		var raw: Variant = data.get(section, null)
		if not (raw is Dictionary):
			errors.append("difficulty.json: section %s is missing" % section)
			continue
		_load_section(section, raw)
	preset = _default_preset
	return errors.is_empty()


## §2.9 rule 1 — the four names, in order, and nothing else.
func _check_presets(meta: Dictionary) -> void:
	var raw: Variant = meta.get("presets", [])
	var listed: Array = raw if raw is Array else []
	if listed.size() != PRESETS.size():
		errors.append("meta.presets must be exactly %s" % str(PRESETS))
		return
	for i in PRESETS.size():
		if String(listed[i]) != PRESETS[i]:
			errors.append("meta.presets[%d] must be %s, got %s"
					% [i, PRESETS[i], String(listed[i])])


## §3.4 rule 2 — the section keys are fixed, and a top-level key that is not one
## of them (and not a note) is the fifth scalar this rule exists to stop.
func _check_sections(meta: Dictionary, data: Dictionary) -> void:
	var raw: Variant = meta.get("sections", {})
	var declared: Dictionary = raw if raw is Dictionary else {}
	for section in SECTIONS:
		if not declared.has(section):
			errors.append("meta.sections is missing %s" % section)
	for key: Variant in declared:
		if not SECTIONS.has(String(key)):
			errors.append("meta.sections names an unknown section %s" % String(key))
	for key: Variant in data:
		var name := String(key)
		if name.begins_with("_") or name == "meta" or SECTIONS.has(name):
			continue
		errors.append("difficulty.json: %s is not a declared section (C-17)" % name)


func _load_section(section: String, block: Dictionary) -> void:
	var directions: Dictionary = {}
	var raw_dir: Variant = block.get("_direction", {})
	if raw_dir is Dictionary:
		for key: Variant in (raw_dir as Dictionary):
			var word := String((raw_dir as Dictionary)[key])
			if word != "up" and word != "down":
				errors.append("%s._direction.%s must be up|down" % [section, String(key)])
				continue
			directions[String(key)] = word
	_directions[section] = directions

	var rows: Dictionary = {}
	for preset_name in PRESETS:
		var raw: Variant = block.get(preset_name, null)
		if not (raw is Dictionary) or (raw as Dictionary).is_empty():
			errors.append("%s.%s is missing — a missing row is a load error (§2.9 rule 1)"
					% [section, preset_name])
			continue
		rows[preset_name] = _scalars(section, preset_name, raw)
	_sections[section] = rows
	if rows.size() != PRESETS.size():
		return
	_check_key_parity(section, rows)
	_check_monotonicity(section, rows, directions)


## §3.4 rule 3 — scalars only. A nested table here would be a knob the loader
## cannot compare across presets, which is how monotonicity stops being checkable.
func _scalars(section: String, preset_name: String, raw: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key: Variant in raw:
		var name := String(key)
		if name.begins_with("_"):
			continue
		var value: Variant = raw[key]
		match typeof(value):
			TYPE_INT, TYPE_FLOAT, TYPE_BOOL:
				out[name] = value
			_:
				errors.append("%s.%s.%s must be a scalar (§3.4 rule 3)"
						% [section, preset_name, name])
	return out


## Every preset carries the same knobs, or a knob silently vanishes on one
## difficulty and reads as its caller's fallback — which is the silent default
## rule 1 forbids, one level down.
func _check_key_parity(section: String, rows: Dictionary) -> void:
	var reference: Dictionary = rows[PRESETS[0]]
	for preset_name in PRESETS:
		var row: Dictionary = rows[preset_name]
		for key: Variant in reference:
			if not row.has(key):
				errors.append("%s.%s is missing knob %s" % [section, preset_name, String(key)])
		for key: Variant in row:
			if not reference.has(key):
				errors.append("%s.%s has knob %s that %s does not"
						% [section, preset_name, String(key), PRESETS[0]])


## §3.4 rule 4 — the casual→crisis sequence of every declared scale is strictly
## monotone in the direction its owner declared, and a knob whose NAME says it is
## a scale must declare one. Strict, not weak: two presets that agree on a
## multiplier are two presets that are the same game in that dimension, and the
## file should say so by not carrying the knob.
func _check_monotonicity(section: String, rows: Dictionary, directions: Dictionary) -> void:
	var reference: Dictionary = rows[PRESETS[0]]
	for key: Variant in reference:
		var name := String(key)
		var declared := String(directions.get(name, ""))
		if declared == "":
			if _is_scale(name):
				errors.append("%s.%s must declare a _direction (§3.4 rule 4)"
						% [section, name])
			continue
		if typeof(reference[key]) == TYPE_BOOL:
			errors.append("%s.%s is a bool and cannot be monotone" % [section, name])
			continue
		# A knob that is missing on one preset has already been reported by
		# `_check_key_parity`; comparing four values when there are three would
		# only bury that error under a crash.
		var complete := true
		for preset_name in PRESETS:
			complete = complete and (rows[preset_name] as Dictionary).has(name)
		if not complete:
			continue
		var previous := float(rows[PRESETS[0]][key])
		for i in range(1, PRESETS.size()):
			var current := float(rows[PRESETS[i]][key])
			var ok := current > previous if declared == "up" else current < previous
			if not ok:
				errors.append("%s.%s is not monotone %s: %s %f -> %s %f"
						% [section, name, declared, PRESETS[i - 1], previous,
						PRESETS[i], current])
			previous = current


static func _is_scale(name: String) -> bool:
	for prefix in SCALE_PREFIXES:
		if name.begins_with(prefix):
			return true
	for suffix in SCALE_SUFFIXES:
		if name.ends_with(suffix):
			return true
	return false


# ------------------------------------------------------------------- reading

func is_valid() -> bool:
	return errors.is_empty()


static func is_preset(name: String) -> bool:
	return PRESETS.has(name)


func preset_names() -> Array[String]:
	return PRESETS.duplicate()


func default_preset() -> String:
	return _default_preset


## Pins the preset for the life of this object. Refuses an unknown name rather
## than falling back, because a typo that silently played `standard` is exactly
## the class of bug A91-D-19 was.
func select(name: String) -> bool:
	if not PRESETS.has(name):
		return false
	preset = name
	return true


## The whole section row for the live preset — what `Treasury` is constructed
## with and what `DisasterDirector.set_pressure_knobs()` is handed.
func row(section: String) -> Dictionary:
	return row_of(section, preset)


func row_of(section: String, preset_name: String) -> Dictionary:
	var rows: Dictionary = _sections.get(section, {})
	var out: Variant = rows.get(preset_name, {})
	return (out as Dictionary).duplicate() if out is Dictionary else {}


## §3.4 rule 5's single read path (see the class docs for the spelling). The
## fallback is for a knob a section legitimately does not carry — never for a
## knob a broken file dropped, which `load_from` has already refused.
func value(section: String, key: String, fallback: Variant = 1.0) -> Variant:
	var rows: Dictionary = _sections.get(section, {})
	var current: Variant = rows.get(preset, {})
	if current is Dictionary and (current as Dictionary).has(key):
		return (current as Dictionary)[key]
	return fallback


func number(section: String, key: String, fallback: float = 1.0) -> float:
	return float(value(section, key, fallback))


func flag(section: String, key: String, fallback: bool = true) -> bool:
	return bool(value(section, key, fallback))
