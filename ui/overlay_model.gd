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
##
## WATER (mode 2) and TRAFFIC (mode 5) added their **classifiers** here rather
## than in the renderer, for the same reason the mode list lives here: the
## thresholds are §2.5's, they are authored in `data/ui.json.overlay`, and both
## the thing that colours pixels and the thing that draws the legend have to
## read the identical table or the legend lies. Neither classifier touches a
## sim: `water_state(factor)` takes a number doc 05 already publishes per
## building, `traffic_band(c)` takes doc 10's congestion index, and this file
## stays headless.

const MODE_NONE := &"none"
const MODE_POWER := &"power"
const MODE_WATER := &"water"
const MODE_TRAFFIC := &"traffic"

## Verdicts from `select()` / `toggle()`.
const REASON_OK := &"ok"
const REASON_UNKNOWN := &"unknown_mode"
const REASON_DISABLED := &"disabled"

const _DEFAULT_MODES := ["none", "power", "water", "police", "fire", "traffic"]
const _DEFAULT_STATES := ["normal", "warning", "critical", "offline"]
const _DEFAULT_SHADER_GLOBAL := "sc_overlay_mode"

## The four data states in doc 11's packing order — `overlay_state` 0..3, which
## is what `RenderStateModel.OVERLAY_*` and the shader's `overlay_of()` read.
const STATE_ORDER := ["normal", "warning", "critical", "offline"]

const _DEFAULT_WATER_BANDS := [
	{"state": "offline", "max": 0.05},
	{"state": "critical", "max": 0.35},
	{"state": "warning", "max": 0.75},
	{"state": "normal", "max": 1.01},
]
## Doc 10 §2.15's own cut points (`RoadCosts.overlay_band`). Only a fallback:
## `data/ui.json.overlay.traffic_bands` is authoritative and the suite asserts
## the two agree.
const _DEFAULT_TRAFFIC_BANDS := [
	{"band": "clear", "max": 0.25, "state": "normal"},
	{"band": "light", "max": 0.50, "state": "normal"},
	{"band": "heavy", "max": 0.75, "state": "warning"},
	{"band": "severe", "max": 0.90, "state": "critical"},
	{"band": "gridlock", "max": 1.01, "state": "critical"},
]

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
##
## `mode` only changes the WORDS: WATER says "Full pressure / Low pressure / …"
## instead of "Normal / Warning / …" when `data/strings.en.json` carries the
## water phrasing, because "warning" is not what a player calls a tap that
## dribbles. The states, glyphs, dashes and pulse rates are the same four rows
## whatever the mode — they are doc 11's 2 bits, and the legend must not imply
## a fifth. TRAFFIC is not a per-building state at all, so it gets its own
## five-row band legend below.
func legend_rows(mode: StringName = MODE_NONE) -> Array[Dictionary]:
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
			"mode_label_key": OverlayModel.state_label_key(mode, state),
		})
	return out


## The legend row the rail should render for `mode`: TRAFFIC's five congestion
## bands, everything else's four data states.
func legend_rows_for(mode: StringName) -> Array[Dictionary]:
	return traffic_legend_rows() if mode == MODE_TRAFFIC else legend_rows(mode)


## `ui_overlay_water_<state>` for WATER, `ui_overlay_state_<state>` otherwise.
## A view resolves this through `UIWidgets.t` with the plain state key as the
## fallback, so a mode with no bespoke phrasing simply reads the generic words.
static func state_label_key(mode: StringName, state: String) -> String:
	if mode == MODE_WATER:
		return "ui_overlay_water_%s" % state
	return "ui_overlay_state_%s" % state


# ---------------------------------------------------------------------------
# WATER (mode 2) — doc 05's per-building service factor → doc 11's 2 bits
# ---------------------------------------------------------------------------

## `overlay.water_bands`, sorted ascending by `max`, first match wins.
func water_bands() -> Array:
	var raw: Variant = _overlay.get("water_bands", _DEFAULT_WATER_BANDS)
	return raw if raw is Array and not (raw as Array).is_empty() else _DEFAULT_WATER_BANDS


## One building's water reading on [0,1] — `WaterSystem.service_factors()`'s
## pressure factor, or `get_water_service(id).pressure`, either is on the same
## scale — as the state NAME the legend prints.
func water_state_name(factor: float) -> StringName:
	var value := clampf(factor, 0.0, 1.0)
	var rows := water_bands()
	for raw: Variant in rows:
		if not (raw is Dictionary):
			continue
		var row: Dictionary = raw
		if value <= UIConfig.get_num(row, "max", 1.0):
			return StringName(str(row.get("state", "normal")))
	var last: Variant = rows[rows.size() - 1]
	return StringName(str((last as Dictionary).get("state", "normal"))) if last is Dictionary \
			else HudModel.STATE_NORMAL


## The same answer as the int doc 11 packs into the instance buffer
## (`RenderStateModel.OVERLAY_NORMAL` … `OVERLAY_OFFLINE`). This is what the
## shell feeds `set_overlay_channel(&"water", …)`.
func water_state(factor: float) -> int:
	return maxi(0, STATE_ORDER.find(String(water_state_name(factor))))


## Bulk form: `{id: factor}` in, `{id: state_int}` out — one call per hourly
## feed, so the shell writes no thresholds of its own. Ids are copied through
## untouched, which is what lets the caller hand over sim ids or render ids.
func water_states(factors: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for key: Variant in factors:
		out[key] = water_state(float(factors[key]))
	return out


# ---------------------------------------------------------------------------
# TRAFFIC (mode 5) — doc 10's per-EDGE congestion index
# ---------------------------------------------------------------------------

func traffic_bands() -> Array:
	var raw: Variant = _overlay.get("traffic_bands", _DEFAULT_TRAFFIC_BANDS)
	return raw if raw is Array and not (raw as Array).is_empty() else _DEFAULT_TRAFFIC_BANDS


## Doc 10 §2.15's band name for a congestion index. The cut points live in
## `data/ui.json` and the suite asserts they still match `RoadCosts.overlay_band`
## — the sim's snapshot already carries the name, so this exists for the paths
## that hold only the number (and for the test that pins the two together).
func traffic_band(congestion: float) -> StringName:
	var rows := traffic_bands()
	for raw: Variant in rows:
		if not (raw is Dictionary):
			continue
		var row: Dictionary = raw
		if congestion < UIConfig.get_num(row, "max", 1.0):
			return StringName(str(row.get("band", "clear")))
	var last: Variant = rows[rows.size() - 1]
	return StringName(str((last as Dictionary).get("band", "gridlock"))) if last is Dictionary \
			else &"gridlock"


func traffic_band_index(band: StringName) -> int:
	var rows := traffic_bands()
	for i in rows.size():
		var row: Variant = rows[i]
		if row is Dictionary and StringName(str((row as Dictionary).get("band", ""))) == band:
			return i
	return 0


## Everything the road overlay needs for one band, resolved: the state token it
## borrows its hue from, how much to deepen it, the wash alpha, the hatch duty
## and the pulse. `index` is what the renderer writes per instance.
func traffic_band_row(band: StringName) -> Dictionary:
	var rows := traffic_bands()
	var i := traffic_band_index(band)
	var row: Dictionary = rows[i] if rows[i] is Dictionary else {}
	return {
		"band": band,
		"index": i,
		"state": StringName(str(row.get("state", "normal"))),
		"darken": UIConfig.get_num(row, "darken", 0.0),
		"alpha": UIConfig.get_num(row, "alpha", 0.0),
		"stripe_duty": UIConfig.get_num(row, "stripe_duty", 0.0),
		"pulse_hz": UIConfig.get_num(row, "pulse_hz", 0.0),
	}


## The five congestion rows the rail prints while TRAFFIC is live. Same shape as
## `legend_rows()` so one view function draws both, and every row still carries
## a glyph and a hatch density — the two channels that survive greyscale.
func traffic_legend_rows() -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw: Variant in traffic_bands():
		if not (raw is Dictionary):
			continue
		var row: Dictionary = raw
		var band := str(row.get("band", ""))
		var glyph_name := str(row.get("glyph",
				_state_glyphs.get(str(row.get("state", "normal")), "")))
		out.append({
			"state": StringName(str(row.get("state", "normal"))),
			"band": StringName(band),
			"glyph_name": glyph_name,
			"glyph": str(HudModel.STATE_GLYPH_CHARS.get(glyph_name, "")),
			"dash": _state_dash.get(str(row.get("state", "normal")), [1, 0]),
			"pulse_hz": UIConfig.get_num(row, "pulse_hz", 0.0),
			"stripe_duty": UIConfig.get_num(row, "stripe_duty", 0.0),
			"label_key": "ui_overlay_band_%s" % band,
			"mode_label_key": "ui_overlay_band_%s" % band,
		})
	return out


## Road-overlay geometry and animation, all of it `data/ui.json.overlay`.
func traffic_render_opts() -> Dictionary:
	return {
		"tile_y_m": UIConfig.get_num(_overlay, "traffic_tile_y_m", 0.16),
		"stripe_period_m": UIConfig.get_num(_overlay, "traffic_stripe_period_m", 5.6),
		"stripe_scroll_m_s": UIConfig.get_num(_overlay, "traffic_stripe_scroll_m_s", 1.8),
		"wash_floor": UIConfig.get_num(_overlay, "traffic_wash_floor", 0.45),
		"refresh_game_minutes": UIConfig.get_num(_overlay,
				"traffic_refresh_game_minutes", 1.0),
	}


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
