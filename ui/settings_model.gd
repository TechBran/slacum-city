class_name SettingsModel
extends RefCounted
## S9's logic (doc 12 §2.13), headless and Node-free: the option lists, the
## validation, the display strings and the save/restore of the `ui.settings`
## block (§3.2). `ui/settings_sheet.gd` renders exactly what `rows()` returns and
## decides nothing.
##
## Every row is **data** (`data/ui.json.settings.rows`). A row's options come
## from wherever that data points — `render_presets` resolves against doc 11's
## `data/render.json` so the graphics preset list can never drift from the
## presets that actually exist, and `text_scale_options` resolves against this
## file's own A2 list. No option list and no default is authored here.
##
## Migration policy (§3.2): "unknown settings keys are dropped, missing keys take
## defaults from `data/ui.json` — a settings change must never invalidate a
## city". `restore_state()` implements exactly that, which is why it takes a raw
## Dictionary and returns the keys it ignored rather than failing.

const KIND_CHOICE := &"choice"
const KIND_TOGGLE := &"toggle"
const KIND_SLIDER := &"slider"

const SOURCE_RENDER_PRESETS := "render_presets"
const SOURCE_TEXT_SCALE := "text_scale_options"

## A row may declare that it writes another document's state rather than a UI
## preference. `policy: "dispatch"` marks §2.13's auto-response rows: their
## defaults come from doc 06's `data/dispatch.json.policy_defaults` and their
## values go to `CitySim.cmd_set_dispatch_policy`, so `data/ui.json` describes
## the *control* and never the number behind it (D-11).
const POLICY_DISPATCH := "dispatch"
const DEFAULT_FROM_DEFAULTS := "defaults."
const DEFAULT_FROM_DISPATCH := "dispatch."

## Fallback preset order if `data/render.json` is absent (doc 11 authors it).
const _DEFAULT_PRESETS := ["performance", "balanced", "high"]
const _EPSILON := 0.0005

var _cfg: UIConfig
var _settings: Dictionary = {}
var _defaults: Dictionary = {}
var _rows: Array = []
var _values: Dictionary = {}
## Doc 03 §2.9's preset, as REPORTED by the shell. Empty until a city is bound —
## S9 can be opened over the title door, where there is no city to report on.
var _city_difficulty: String = ""


func _init(cfg: UIConfig = null) -> void:
	if cfg == null:
		return
	_cfg = cfg
	_settings = cfg.section("settings")
	_defaults = cfg.section("defaults")
	var raw: Variant = _settings.get("rows", [])
	_rows = raw if raw is Array else []
	reset_to_defaults()


static func load_from_files() -> SettingsModel:
	return SettingsModel.new(UIConfig.load_from_files())


func reset_to_defaults() -> void:
	_values.clear()
	for raw: Variant in _rows:
		if not (raw is Dictionary):
			continue
		var row: Dictionary = raw
		_values[str(row.get("key", ""))] = _default_for(row)


# ---------------------------------------------------------------------------
# Row definitions
# ---------------------------------------------------------------------------

func keys() -> Array[String]:
	var out: Array[String] = []
	for raw: Variant in _rows:
		if raw is Dictionary:
			out.append(str((raw as Dictionary).get("key", "")))
	return out


func has_key(key: String) -> bool:
	return _row_def(key) is Dictionary and not (_row_def(key) as Dictionary).is_empty()


func _row_def(key: String) -> Dictionary:
	for raw: Variant in _rows:
		if raw is Dictionary and str((raw as Dictionary).get("key", "")) == key:
			return raw
	return {}


func kind(key: String) -> StringName:
	return StringName(str(_row_def(key).get("kind", String(KIND_TOGGLE))))


## `""` for a plain UI preference, `POLICY_DISPATCH` for one of §2.13's
## auto-response rows. `UIRoot` reads this to decide where a change goes.
func policy_of(key: String) -> String:
	return str(_row_def(key).get("policy", ""))


## Every row that writes `policy`, in sheet order — the set `UIRoot` seeds from
## the live sim on bind, so a saved city's policies win over a data default.
func policy_keys(policy: String) -> Array[String]:
	var out: Array[String] = []
	for key: String in keys():
		if policy_of(key) == policy:
			out.append(key)
	return out


## The option list for a `choice` row, resolved through `options_from` when the
## row does not carry one inline.
func options(key: String) -> Array:
	var row := _row_def(key)
	if row.has("options"):
		var inline: Variant = row["options"]
		return (inline as Array).duplicate() if inline is Array else []
	match str(row.get("options_from", "")):
		SOURCE_RENDER_PRESETS:
			return graphics_presets()
		SOURCE_TEXT_SCALE:
			var raw: Variant = _cfg.ui_data().get("text_scale_options", []) if _cfg != null else []
			return (raw as Array).duplicate() if raw is Array else []
	return []


## Doc 11's presets, ordered cheapest-first by `render_scale` so the choice row
## reads Performance → Balanced → High without this file knowing those names.
func graphics_presets() -> Array:
	var render: Dictionary = _cfg.render_data() if _cfg != null else {}
	var raw: Variant = render.get("presets", null)
	if not (raw is Dictionary) or (raw as Dictionary).is_empty():
		return _DEFAULT_PRESETS.duplicate()
	var presets: Dictionary = raw
	var names: Array = presets.keys()
	names.sort()  # stable base order before the numeric sort below
	names.sort_custom(func(a: Variant, b: Variant) -> bool:
		var pa: Dictionary = presets[a]
		var pb: Dictionary = presets[b]
		var sa := UIConfig.get_num(pa, "render_scale", 1.0)
		var sb := UIConfig.get_num(pb, "render_scale", 1.0)
		if is_equal_approx(sa, sb):
			return str(a) < str(b)
		return sa < sb)
	return names


func _default_for(row: Dictionary) -> Variant:
	if row.has("default"):
		return row["default"]
	var from := str(row.get("default_from", ""))
	if from.begins_with(DEFAULT_FROM_DEFAULTS):
		var name := from.substr(DEFAULT_FROM_DEFAULTS.length())
		if _defaults.has(name):
			return _defaults[name]
	elif from.begins_with(DEFAULT_FROM_DISPATCH):
		# Doc 06 owns the number; this row owns only the control that shows it.
		var policy: Dictionary = _cfg.dispatch_policy_defaults() if _cfg != null else {}
		var name := from.substr(DEFAULT_FROM_DISPATCH.length())
		if policy.has(name):
			return policy[name]
	var key := str(row.get("key", ""))
	var choices := options(key)
	if not choices.is_empty():
		return choices[0]
	if str(row.get("kind", "")) == String(KIND_SLIDER):
		return UIConfig.get_num(row, "min", 0.0)
	return false


# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

func value(key: String) -> Variant:
	return _values.get(key, null)


func value_bool(key: String) -> bool:
	return bool(_values.get(key, false))


func value_num(key: String) -> float:
	var raw: Variant = _values.get(key, 0.0)
	return float(raw) if raw is float or raw is int else 0.0


func value_text_key(key: String) -> String:
	return "ui_settings_row_%s" % key


## Validates against the row's kind: an unknown key or an out-of-list option is
## refused outright rather than silently coerced. Returns true when the stored
## value actually changed.
func set_value(key: String, new_value: Variant) -> bool:
	var row := _row_def(key)
	if row.is_empty():
		return false
	var kind_id := kind(key)
	var coerced: Variant = new_value
	# A wrong-typed value is refused rather than coerced: `"loud"` becoming 0 %
	# would look like a successful restore of a broken save (§3.2 wants it
	# dropped, and the default kept).
	if kind_id != KIND_CHOICE and not (new_value is bool or new_value is int
			or new_value is float):
		return false
	if kind_id == KIND_TOGGLE:
		coerced = bool(new_value)
	elif kind_id == KIND_SLIDER:
		var lo := UIConfig.get_num(row, "min", 0.0)
		var hi := UIConfig.get_num(row, "max", 1.0)
		var step := UIConfig.get_num(row, "step", 0.1)
		var raw := clampf(float(new_value), lo, hi)
		coerced = clampf(lo + round((raw - lo) / maxf(step, 0.0001)) * step, lo, hi)
	else:
		var choices := options(key)
		var matched := false
		for choice: Variant in choices:
			if _same_option(choice, new_value):
				coerced = choice
				matched = true
				break
		if not matched:
			return false
	if _same_option(_values.get(key, null), coerced):
		return false
	_values[key] = coerced
	return true


## One tap on a `choice` row advances to the next option and wraps — a settings
## row is a 48 dp target, not a dropdown (A3).
func cycle(key: String) -> Variant:
	var choices := options(key)
	if choices.is_empty():
		return value(key)
	var index := 0
	for i in choices.size():
		if _same_option(choices[i], value(key)):
			index = i
			break
	_values[key] = choices[(index + 1) % choices.size()]
	return _values[key]


func toggle(key: String) -> bool:
	if kind(key) != KIND_TOGGLE:
		return value_bool(key)
	_values[key] = not value_bool(key)
	return bool(_values[key])


## Slider step, `direction` ∈ {-1, +1}. Wraps to the far end so one button can
## drive the whole range with no second target (A3/A4 again).
func step_slider(key: String, direction: int) -> float:
	var row := _row_def(key)
	if row.is_empty() or kind(key) != KIND_SLIDER:
		return value_num(key)
	var lo := UIConfig.get_num(row, "min", 0.0)
	var hi := UIConfig.get_num(row, "max", 1.0)
	var step := UIConfig.get_num(row, "step", 0.1)
	var next := value_num(key) + step * float(signi(direction))
	if next > hi + _EPSILON:
		next = lo
	elif next < lo - _EPSILON:
		next = hi
	set_value(key, next)
	return value_num(key)


static func _same_option(a: Variant, b: Variant) -> bool:
	if a == null or b == null:
		return a == null and b == null
	if (a is float or a is int) and (b is float or b is int):
		return absf(float(a) - float(b)) <= _EPSILON
	if a is bool or b is bool:
		return bool(a) == bool(b)
	return str(a) == str(b)


# ---------------------------------------------------------------------------
# What the sheet renders
# ---------------------------------------------------------------------------

## One dictionary per settings row: kind, current value, the accessibility label
## key and the already-resolved value text. The view binds; it never formats.
func rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw: Variant in _rows:
		if not (raw is Dictionary):
			continue
		var row: Dictionary = raw
		var key := str(row.get("key", ""))
		out.append({
			"key": key,
			"kind": kind(key),
			"label_key": value_text_key(key),
			"value": value(key),
			"value_text": value_text(key),
			"options": options(key),
			"min": UIConfig.get_num(row, "min", 0.0),
			"max": UIConfig.get_num(row, "max", 1.0),
			"step": UIConfig.get_num(row, "step", 0.1),
			"device_scoped": device_scoped_keys().has(key),
			"policy": policy_of(key),
			"hint_key": str(row.get("hint_key", "")),
		})
	return out


## The display value, resolved from `data/strings.en.json` (G-8). Special-cased
## per row family because "Every 5 min", "85%" and "On" are three different
## sentences, not one format.
func value_text(key: String) -> String:
	var kind_id := kind(key)
	if kind_id == KIND_TOGGLE:
		return _t("ui_settings_value_on" if value_bool(key) else "ui_settings_value_off")
	if key == "sound_volume" or key == "text_scale":
		return _t_args("ui_settings_value_percent",
				{"n": int(round(value_num(key) * 100.0))})
	if key == "autosave_interval_min":
		var minutes := int(round(value_num(key)))
		if minutes <= 0:
			return _t("ui_settings_value_autosave_off")
		return _t_args("ui_settings_value_autosave_min", {"n": minutes})
	if key == "graphics":
		return _t("ui_settings_value_graphics_%s" % str(value(key)))
	# §2.14's three-way row and §2.13's money ladder are the two families whose
	# value is a *word* or a *sum* rather than the stored value; both say so in
	# `data/ui.json` (`value_text_from` / `value_format`) rather than by key name,
	# so a new row of either shape needs no branch here.
	var row := _row_def(key)
	var family := str(row.get("value_text_from", ""))
	if family != "":
		return _t("ui_settings_value_%s_%s" % [family, str(value(key))])
	if str(row.get("value_format", "")) == "money":
		return HudModel.money_exact(int(round(value_num(key))))
	return str(value(key))


## About page rows — version from `project.godot`, engine from the runtime, both
## as `{named}` arguments into the string table rather than concatenated copy.
func about_rows() -> Array[Dictionary]:
	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	var engine_version: Dictionary = Engine.get_version_info()
	return [
		{"label_key": "ui_settings_about_version",
			"args": {"version": version if version != "" else HudModel.NO_DATA},
			"text": _t_args("ui_settings_about_version",
					{"version": version if version != "" else HudModel.NO_DATA})},
		{"label_key": "ui_settings_about_engine",
			"args": {"engine": str(engine_version.get("string", ""))},
			"text": _t_args("ui_settings_about_engine",
					{"engine": str(engine_version.get("string", ""))})},
	]


## ---------------------------------------------------------------------------
## The city block — read-only, and read-only is the whole point
## ---------------------------------------------------------------------------
##
## Doc 03 §2.9's difficulty is chosen when a city is FOUNDED and kept for life
## (doc 93 §K1). That makes it the one thing on this screen that is a property of
## the CITY rather than a preference of the app, so it has no `key`, no row in
## `data/ui.json.settings.rows`, no default and no `set_value` path: it is
## reported by the shell and rendered as a sentence, beside About.
##
## §2.9's own text once allowed raising difficulty at any time and lowering it
## with an `assisted` flag. That is ruled out in doc 93 §K1 and the reasons are
## there; what matters here is that a screen with a control the sim refuses would
## be a lie, and a screen with no mention at all would leave a player unable to
## find out what they are playing. A sentence is the honest third answer.

## Called by `UIRoot.set_city_difficulty` with `CitySim.difficulty_preset()`.
func set_city_difficulty(preset: String) -> void:
	_city_difficulty = preset


func city_difficulty() -> String:
	return _city_difficulty


## Zero rows until a city is bound, one row after — the same shape `about_rows()`
## returns, so `SettingsSheet` renders both with one loop.
func city_rows() -> Array[Dictionary]:
	if _city_difficulty == "":
		return [] as Array[Dictionary]
	var word := _t("ui_title_difficulty_%s" % _city_difficulty)
	return [{
		"label_key": "ui_settings_city_difficulty",
		"args": {"value": word},
		"value_text": word,
		"text": _t_args("ui_settings_city_difficulty", {"value": word}),
	}]


func device_scoped_keys() -> Array:
	var raw: Variant = _settings.get("device_scoped_keys", [])
	return (raw as Array) if raw is Array else []


## Where the device-scoped copy lives (constitution §2): these survive city
## deletion and checkpoint rollback, and win over the per-city snapshot on load.
func settings_file_path() -> String:
	return str(_settings.get("settings_file", "user://settings.cfg"))


## Autosave cadence in real seconds for the shell's timer; 0 means "off".
func autosave_interval_s() -> float:
	return maxf(0.0, value_num("autosave_interval_min")) * 60.0


func _t(key: String) -> String:
	return _cfg.t(key) if _cfg != null else key


func _t_args(key: String, args: Dictionary) -> String:
	return _cfg.t(key, args) if _cfg != null else key


# ---------------------------------------------------------------------------
# Persistence (§3.2 `ui.settings`)
# ---------------------------------------------------------------------------

func capture_state() -> Dictionary:
	var out: Dictionary = {}
	for key: String in keys():
		out[key] = _values.get(key, null)
	return out


## Unknown keys are dropped and missing keys keep their default, so an old save
## can never invalidate a city. Returns the dropped keys for the caller's log.
func restore_state(state: Dictionary) -> PackedStringArray:
	reset_to_defaults()
	var dropped: PackedStringArray = []
	var incoming: Array = state.keys()
	incoming.sort()  # deterministic apply order, deterministic dropped list
	for key: Variant in incoming:
		var name := str(key)
		if not _row_def(name).is_empty():
			if not set_value(name, state[key]):
				# An unchanged value is fine; an invalid one is a drop.
				if not _same_option(_values.get(name, null), state[key]):
					dropped.append(name)
			continue
		dropped.append(name)
	return dropped


## The theme-affecting subset, in the shape `ThemeBuilder.build()` expects.
func theme_opts() -> Dictionary:
	return {
		"text_scale": value_num("text_scale") if has_key("text_scale") else 1.0,
		"larger_touch_targets": value_bool("larger_touch_targets"),
		"colorblind": str(_defaults.get("colorblind", "default")),
	}
