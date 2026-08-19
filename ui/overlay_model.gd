class_name OverlayModel
extends RefCounted
## The overlay rail's logic (doc 12 §2.5), headless and Node-free: which
## overlays exist, which are live, which one is active, and the integer doc 11
## reads out of the `sc_overlay_mode` shader global.
##
## Two rules from §2.5 are the whole class:
##   * overlays are **mutually exclusive** in MVP — selecting one deselects the
##     rest, and tapping the active chip returns to `none`;
##   * long-pressing the overlay button toggles `NONE ↔ last-used overlay`, the
##     fast A/B compare a player uses while reading a cascade.
##
## An overlay whose sim has not landed is **listed, greyed and explained** rather
## than hidden (A14: every blocked action states its reason in words), so the
## console never changes shape as docs 05/06/10 arrive. `data/ui.json.overlay`
## owns the mode list, the enabled subset and the shader global's name; nothing
## here is authored in code.
##
## The four data states this class publishes for the legend are the same four
## `data/ui.json.state_*` rows that doc 11 packs into 2 bits per instance
## (C-64) — SELECTED is not one of them and never appears here.

const MODE_NONE := &"none"

## Verdicts from `select()` / `toggle()`.
const REASON_OK := &"ok"
const REASON_UNKNOWN := &"unknown_mode"
const REASON_DISABLED := &"disabled"

const _DEFAULT_MODES := ["none", "power", "water", "police", "fire", "traffic"]
const _DEFAULT_STATES := ["normal", "warning", "critical", "offline"]
const _DEFAULT_SHADER_GLOBAL := "sc_overlay_mode"

var _overlay: Dictionary = {}
var _state_glyphs: Dictionary = {}
var _state_dash: Dictionary = {}
var _state_pulse: Dictionary = {}

var _active: StringName = MODE_NONE
## Last non-`none` overlay, for the §2.5 long-press A/B compare. Persisted with
## the rest of the `ui` save section so the compare survives a resume.
var _last: StringName = MODE_NONE


func _init(cfg: UIConfig = null) -> void:
	if cfg == null:
		return
	_overlay = cfg.section("overlay")
	_state_glyphs = cfg.section("state_glyphs")
	_state_dash = cfg.section("state_dash")
	_state_pulse = cfg.section("state_pulse_hz")


static func load_from_files() -> OverlayModel:
	return OverlayModel.new(UIConfig.load_from_files())


# ---------------------------------------------------------------------------
# The mode list
# ---------------------------------------------------------------------------

func modes() -> Array[StringName]:
	var raw: Variant = _overlay.get("modes", _DEFAULT_MODES)
	var source: Array = raw if raw is Array else _DEFAULT_MODES
	var out: Array[StringName] = []
	for value: Variant in source:
		out.append(StringName(str(value)))
	return out if not out.is_empty() else ([MODE_NONE] as Array[StringName])


## The integer doc 11 reads from `sc_overlay_mode`: the mode's index into
## `overlay.modes`. `-1` means the mode is not in the list at all.
func mode_index(mode: StringName) -> int:
	var all := modes()
	for i in all.size():
		if all[i] == mode:
			return i
	return -1


func has_mode(mode: StringName) -> bool:
	return mode_index(mode) >= 0


func shader_global_name() -> String:
	return str(_overlay.get("shader_global", _DEFAULT_SHADER_GLOBAL))


## An overlay is enabled once the sim behind it publishes its `OverlayQuery`.
## `none` is always enabled — turning overlays off can never be blocked.
func is_enabled(mode: StringName) -> bool:
	if mode == MODE_NONE:
		return true
	if not has_mode(mode):
		return false
	var raw: Variant = _overlay.get("enabled_modes", null)
	if not (raw is Array):
		return true  # no allow-list authored: everything listed is live
	for value: Variant in (raw as Array):
		if StringName(str(value)) == mode:
			return true
	return false


static func label_key(mode: StringName) -> String:
	return "ui_overlay_mode_%s" % String(mode)


# ---------------------------------------------------------------------------
# Selection
# ---------------------------------------------------------------------------

func active() -> StringName:
	return _active


func active_index() -> int:
	return maxi(0, mode_index(_active))


func last_used() -> StringName:
	return _last


## Mutually exclusive selection. Returns
## `{ok, mode, index, changed, reason}` — a refused select never changes the
## active overlay, and `reason` is what the view turns into words (A14).
func select(mode: StringName) -> Dictionary:
	if not has_mode(mode):
		return _verdict(false, REASON_UNKNOWN, false)
	if not is_enabled(mode):
		return _verdict(false, REASON_DISABLED, false)
	var changed := _active != mode
	if changed and mode != MODE_NONE:
		_last = mode
	_active = mode
	return _verdict(true, REASON_OK, changed)


## Chip tap: selecting the overlay that is already active turns it off, so one
## chip is both "show me power" and "put it away".
func toggle(mode: StringName) -> Dictionary:
	if mode != MODE_NONE and _active == mode:
		return select(MODE_NONE)
	return select(mode)


## Long-press on the overlay button: `NONE ↔ last-used` (§2.5). With no history
## it is a no-op rather than a guess.
func toggle_last() -> Dictionary:
	if _active != MODE_NONE:
		return select(MODE_NONE)
	if _last == MODE_NONE or not is_enabled(_last):
		return _verdict(false, REASON_DISABLED, false)
	return select(_last)


func _verdict(ok: bool, reason: StringName, changed: bool) -> Dictionary:
	return {
		"ok": ok,
		"mode": _active,
		"index": active_index(),
		"changed": changed,
		"reason": reason,
	}


# ---------------------------------------------------------------------------
# What the rail renders
# ---------------------------------------------------------------------------

## One row per overlay, in `data/ui.json` order. `label_key` and
## `disabled_reason_key` resolve through `data/strings.en.json` (G-8); the view
## authors no copy.
func chips() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var all := modes()
	for i in all.size():
		var mode := all[i]
		out.append({
			"id": mode,
			"index": i,
			"label_key": OverlayModel.label_key(mode),
			"enabled": is_enabled(mode),
			"selected": mode == _active,
			"disabled_reason_key": "ui_overlay_disabled",
		})
	return out


## The legend's four state rows (§2.5). Colour is never load-bearing, so every
## row carries a glyph, a dash pattern and a pulse rate alongside its token.
func legend_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	var raw: Variant = _overlay.get("legend_states", _DEFAULT_STATES)
	var states: Array = raw if raw is Array else _DEFAULT_STATES
	for value: Variant in states:
		var state := str(value)
		var glyph_name := str(_state_glyphs.get(state, ""))
		out.append({
			"state": StringName(state),
			"glyph_name": glyph_name,
			"glyph": str(HudModel.STATE_GLYPH_CHARS.get(glyph_name, "")),
			"dash": _state_dash.get(state, [1, 0]),
			"pulse_hz": UIConfig.get_num(_state_pulse, state, 0.0),
			"label_key": "ui_overlay_state_%s" % state,
		})
	return out


# ---------------------------------------------------------------------------
# Persistence — the `ui` save section's `overlay` keys (doc 12 §3.2)
# ---------------------------------------------------------------------------

func capture_state() -> Dictionary:
	return {"overlay": String(_active), "overlay_last": String(_last)}


func restore_state(state: Dictionary) -> void:
	var mode := StringName(str(state.get("overlay", String(MODE_NONE))))
	var last := StringName(str(state.get("overlay_last", String(MODE_NONE))))
	_last = last if has_mode(last) and last != MODE_NONE else MODE_NONE
	_active = MODE_NONE
	# A save written while an overlay was live must not resurrect it once its
	# system has been pulled from the build: the restore goes through `select`.
	if mode != MODE_NONE:
		select(mode)
