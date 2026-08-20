class_name ToastView
extends Control
## Doc 12 §2.15's toast: `320 × 40 dp bottom-centre, 2.5 s, max 1 (newest
## replaces)`. Every dimension is `data/ui.json.layout`'s; this file holds none.
##
## It exists because the deck had a toast *budget* and no toast **surface**. The
## §2.13 in-app gate degrades a banner it cannot afford into a toast
## (`HudModel._degrade`), `AwayReportSheet` returns toast copy when an absence
## was too short for the modal, and the city-level moment (§2.13/§2.15) wants
## one — and all three landed in a queue that nothing drew. `ToastLayer` has been
## in `ui_root.tscn` since the scaffold; this is what lives on it.
##
## Deliberately not a tap target. §2.15 gives a toast an *optional* UNDO and
## nothing here has an undoable action yet, so the whole control is
## `MOUSE_FILTER_IGNORE`: a 40 dp strip that swallows touches over the build FAB
## would be a worse defect than the one it fixes.

const PALETTE_TYPE := "Palette"
const _DEFAULT_TOAST_DP := [320.0, 40.0]
const _DEFAULT_TTL_S := 2.5

var config: UIConfig

var _panel: PanelContainer
var _label: Label
var _ttl_s := _DEFAULT_TTL_S
var _remaining := 0.0
var _text := ""


func setup(cfg: UIConfig = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	var layout := config.layout()
	_ttl_s = UIConfig.get_num(layout, "toast_ttl_s", _DEFAULT_TTL_S)
	var raw: Variant = layout.get("toast_dp", _DEFAULT_TOAST_DP)
	var dims: Array = raw if raw is Array and (raw as Array).size() >= 2 \
			else _DEFAULT_TOAST_DP
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bind_nodes()
	if _panel != null:
		_panel.theme_type_variation = &"ToastPanel"
		_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_panel.custom_minimum_size = Vector2(float(dims[0]), float(dims[1]))
	if _label != null:
		_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_label.clip_text = false
	hide_toast()
	set_process(true)


func _ready() -> void:
	if config == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_panel = get_node_or_null("Panel") as PanelContainer
	_label = get_node_or_null("Panel/Label") as Label


## §2.15: max 1, newest replaces. `state` paints the four-state palette when the
## caller has an opinion; the default is the panel's own text colour.
func show_toast(text: String, state: StringName = &"") -> void:
	if text.strip_edges() == "":
		return
	_text = text
	_remaining = _ttl_s
	if _label != null:
		_label.text = text
		_label.tooltip_text = text
		UIWidgets.paint_state(self, _label, state)
	if _panel != null:
		_panel.visible = true


func hide_toast() -> void:
	_remaining = 0.0
	_text = ""
	if _panel != null:
		_panel.visible = false


func is_open() -> bool:
	return _panel != null and _panel.visible


func text() -> String:
	return _text


## Seconds left, for the tests and the preview harness — a toast that never
## expires is the defect this class is most likely to grow.
func remaining_s() -> float:
	return _remaining


func _process(delta: float) -> void:
	if _remaining <= 0.0:
		return
	_remaining -= delta
	if _remaining <= 0.0:
		hide_toast()
