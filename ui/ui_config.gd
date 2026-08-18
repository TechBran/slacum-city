class_name UIConfig
extends RefCounted
## The single reader for `data/ui.json` (doc 12 §3.1) and `data/strings.en.json`
## (§3.1, G-8). Pure `RefCounted`: parsing is handed a Dictionary, so every
## consumer — `CameraState`, `GestureRecognizer`, `ThemeBuilder`, `UIRoot` — is
## constructible from a fixture with no file IO. `load_from_files()` is the only
## path that touches `FileAccess`, mirroring `BuildingCatalog` / `CostCurves`.
##
## Constitution §3: no magic numbers in code. Nothing in `ui/` may hardcode a
## tunable that lives in `data/ui.json`; the accessors below take a fallback
## purely so a malformed file degrades to a loud error rather than a crash, and
## `errors` is non-empty in that case.
##
## Doc 11 owns the camera *projection* (`fov_deg`, `near_m`, `far_m`) in
## `data/render.json` (report 98 C-63). This class reads them from there when the
## file exists and never from `data/ui.json` — `ui_camera_restates_projection()`
## asserts the separation for doc 12 test 5b.

const UI_JSON_PATH := "res://data/ui.json"
const STRINGS_JSON_PATH := "res://data/strings.en.json"
const RENDER_JSON_PATH := "res://data/render.json"

## Projection keys that belong to doc 11 and must never appear in ui.json.camera.
const PROJECTION_KEYS := ["fov_deg", "near_m", "far_m"]

var errors: PackedStringArray = []

var _ui: Dictionary = {}
var _strings: Dictionary = {}
var _render: Dictionary = {}


func _init(ui: Dictionary = {}, strings: Dictionary = {}, render: Dictionary = {}) -> void:
	_ui = ui
	_strings = strings
	_render = render


static func load_from_files(
		ui_path: String = UI_JSON_PATH,
		strings_path: String = STRINGS_JSON_PATH,
		render_path: String = RENDER_JSON_PATH) -> UIConfig:
	var cfg := UIConfig.new()
	cfg._ui = UIConfig._parse(ui_path, cfg.errors, true)
	cfg._strings = UIConfig._parse(strings_path, cfg.errors, true)
	# data/render.json is doc 11's and is authored separately; its absence is not
	# an error for the UI layer, it just means the projection must be injected.
	cfg._render = UIConfig._parse(render_path, cfg.errors, false)
	return cfg


static func _parse(path: String, sink: PackedStringArray, required: bool) -> Dictionary:
	if not FileAccess.file_exists(path):
		if required:
			sink.append("missing %s" % path)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not (parsed is Dictionary):
		sink.append("cannot parse %s" % path)
		return {}
	return parsed


func is_valid() -> bool:
	return errors.is_empty()


func ui_data() -> Dictionary:
	return _ui


func strings_data() -> Dictionary:
	return _strings


func render_data() -> Dictionary:
	return _render


func has_render_data() -> bool:
	return not _render.is_empty()


## Top-level section of data/ui.json, e.g. "camera", "layout", "gestures_dp_ms".
func section(name: String) -> Dictionary:
	var value: Variant = _ui.get(name, {})
	return value if value is Dictionary else {}


func camera() -> Dictionary:
	return section("camera")


func gestures() -> Dictionary:
	return section("gestures_dp_ms")


func layout() -> Dictionary:
	return section("layout")


func palette(variant: String = "default") -> Dictionary:
	var all := section("palette")
	var base: Variant = all.get("default", {})
	var merged: Dictionary = (base as Dictionary).duplicate() if base is Dictionary else {}
	if variant != "default":
		var over: Variant = all.get(variant, {})
		if over is Dictionary:
			for k: String in (over as Dictionary):
				merged[k] = (over as Dictionary)[k]
		else:
			errors.append("unknown colourblind palette variant '%s'" % variant)
	return merged


## String-table lookup (doc 12 §3.1 `Str.t`). `{named}` placeholders only.
## A missing key returns the key itself — doc 12 test 21 turns that into a
## failure rather than letting a blank label ship.
func t(key: String, args: Dictionary = {}) -> String:
	var value: Variant = _strings.get(key, null)
	if not (value is String):
		return key
	var text: String = value
	for name: String in args:
		text = text.replace("{%s}" % name, str(args[name]))
	return text


func has_string(key: String) -> bool:
	return _strings.get(key, null) is String


## doc 12 test 5b, ui.json half: `data/ui.json.camera` must carry the interaction
## range and NOT the projection. Returns the offending keys (empty == compliant).
func ui_camera_restates_projection() -> PackedStringArray:
	var found: PackedStringArray = []
	var cam := camera()
	for key: String in PROJECTION_KEYS:
		if cam.has(key):
			found.append(key)
	return found


## Vertical FOV in degrees, read from doc 11's data/render.json. Returns
## `fallback` (and records nothing) when that file is not present yet — the
## caller decides whether an absent projection is fatal.
func projection_fov_deg(fallback: float) -> float:
	for key: String in ["camera", "projection"]:
		var block: Variant = _render.get(key, null)
		if block is Dictionary and (block as Dictionary).has("fov_deg"):
			return float((block as Dictionary)["fov_deg"])
	if _render.has("fov_deg"):
		return float(_render["fov_deg"])
	return fallback


static func get_num(source: Dictionary, key: String, fallback: float) -> float:
	var value: Variant = source.get(key, null)
	if value is float or value is int:
		return float(value)
	return fallback


static func get_int(source: Dictionary, key: String, fallback: int) -> int:
	var value: Variant = source.get(key, null)
	if value is float or value is int:
		return int(value)
	return fallback
