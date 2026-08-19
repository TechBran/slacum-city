class_name UnitPickerSheet
extends Control
## The unit picker (doc 12 §2.6 steps 1–5, S7): a 240 dp bottom sheet listing
## every unit that could answer the incident the player just tapped ASSIGN on,
## soonest first, with `AUTO — best available` as the primary target.
##
## It lives on `SheetLayer` because §2.6 says it "rises from the bottom … over
## the drawer": the drawer is on `PanelLayer` and stays visible behind it, while
## `UIWidgets.close_siblings()` puts the build sheet away — you are not placing a
## house and dispatching an engine in the same gesture.
##
## Two taps, total, from a T4 incident to a truck on the road: ASSIGN in the
## drawer, then AUTO or a row here. That is the flow doc 12 calls blocking for
## the slice, and nothing on this screen may add a third tap to it.
##
## The screen issues no command. It emits `dispatch_requested(unit_id,
## incident_id)`; the shell calls `CitySim.cmd_dispatch_unit` and hands the
## verdict back through `report_result()`, so the sheet never predicts success
## (§4.4).

signal dispatch_requested(unit_id: int, incident_id: int)
signal sheet_toggled(open: bool)

var config: UIConfig
var model: UnitPickerModel

var _sheet: PanelContainer
var _title: Label
var _close: Button
var _auto: Button
var _message: Label
var _list: VBoxContainer

var _rows: Dictionary = {}   # unit id:int -> Button
var _touch_min := 48.0
var _spacing := 8.0
var _row_h := 56.0


func setup(cfg: UIConfig = null, p_model: UnitPickerModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else UnitPickerModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	var layout := config.layout()
	_spacing = UIConfig.get_num(layout, "touch_spacing_min_dp", 8.0)
	# A3 again: §2.6's 56 dp unit row is already above the gate, but a 150 % text
	# scale raises the gate past it and the row has to follow.
	_row_h = maxf(UIConfig.get_num(layout, "unit_row_h_dp", 56.0), _touch_min)
	_bind_nodes()
	_build_static()
	close()


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_sheet = get_node_or_null("Sheet") as PanelContainer
	_title = get_node_or_null("Sheet/Body/Header/Title") as Label
	_close = get_node_or_null("Sheet/Body/Header/Close") as Button
	_auto = get_node_or_null("Sheet/Body/Auto") as Button
	_message = get_node_or_null("Sheet/Body/Message") as Label
	_list = get_node_or_null("Sheet/Body/Scroll/List") as VBoxContainer


func _build_static() -> void:
	if _sheet != null:
		_sheet.custom_minimum_size = Vector2(0.0,
				UIConfig.get_num(config.layout(), "unit_picker_h_dp", 240.0))
	if _title != null:
		_title.text = UIWidgets.t(config, "ui_picker_title")
		# See `AlertsCenter`: the scene's `clip_text` alone would let the ✕ beside
		# it claim the whole header.
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _close != null:
		_close.theme_type_variation = &"GhostButton"
		_close.focus_mode = Control.FOCUS_NONE
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		_close.text = "✕"
		_close.tooltip_text = UIWidgets.t(config, "ui_picker_close")
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _auto != null:
		_auto.theme_type_variation = &"PrimaryFAB"
		_auto.focus_mode = Control.FOCUS_NONE
		_auto.custom_minimum_size = Vector2(maxf(_touch_min * 4.0, 200.0), _touch_min)
		_auto.text = UIWidgets.t(config, "ui_picker_auto")
		_auto.tooltip_text = _auto.text
		if not _auto.pressed.is_connected(dispatch_auto):
			_auto.pressed.connect(dispatch_auto)
	if _list != null:
		_list.add_theme_constant_override(&"separation", int(_spacing))


## `Callable(incident_id: int) -> Array[Dictionary]` — see `UnitPickerModel` for
## the row shape. The shell wires it to doc 06's fleet.
func set_provider(provider: Callable) -> void:
	model.set_provider(provider)


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _sheet != null and _sheet.visible


## The one entry point: an `IncidentModel` row, straight off the drawer.
func open_for(incident_row: Dictionary) -> void:
	model.open_for(incident_row)
	# Visible *before* the siblings are told to close: `BuildSheet.close()` decides
	# whether to put its FAB back by asking whether anything else on this layer is
	# open, and the honest answer at that moment is "yes, this sheet".
	if _sheet != null:
		_sheet.visible = true
	UIWidgets.close_siblings(self)
	_refresh()
	sheet_toggled.emit(true)


func close() -> void:
	if _sheet != null:
		_sheet.visible = false
	sheet_toggled.emit(false)


# ---------------------------------------------------------------------------
# Rendering
# ---------------------------------------------------------------------------

func _refresh() -> void:
	if _title != null:
		_title.text = model.header_text()
	var card := model.empty_card()
	if _message != null:
		# A14: an empty sheet still says why, and what would change it.
		_message.text = str(card.get("text", ""))
		_message.visible = not card.is_empty()
	if _auto != null:
		var pick := model.auto_pick()
		_auto.disabled = pick.is_empty()
		_auto.tooltip_text = UIWidgets.t(config, "ui_picker_auto") if pick.is_empty() \
				else "%s — %s" % [UIWidgets.t(config, "ui_picker_auto"),
						str(pick["name"])]
	_refresh_list()


func _refresh_list() -> void:
	if _list == null:
		return
	UIWidgets.clear_children(_list)
	_rows.clear()
	for row: Dictionary in model.rows():
		var button := _build_row(row)
		_list.add_child(button)
		_rows[int(row["id"])] = button


## §2.6 step 3's five columns, folded into a 56 dp target as **two lines** rather
## than four columns. Four columns on a 412 dp phone left the unit's own name
## 47 px of a 73 px word — and the name is what the player is choosing between.
## Line 1 is the choice (name + ETA), line 2 is the qualifier (status + tag), and
## every one of them keeps its full text. An ineligible unit is rendered (so the
## player learns why it cannot go) and disabled (so it cannot be tapped by
## accident).
func _build_row(row: Dictionary) -> Button:
	var unit_id := int(row["id"])
	var eta_text := str(row["eta_text"])
	var tooltip := "%s · %s · %s" % [str(row["name"]), eta_text, str(row["state_text"])]
	var button := UIWidgets.button("Unit_%d" % unit_id, "", tooltip,
			Vector2(_touch_min, _row_h), &"DrawerRow")
	button.disabled = not bool(row["eligible"])
	button.pressed.connect(_on_row_pressed.bind(unit_id))

	var body := VBoxContainer.new()
	body.name = "Body"
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Inside the row, not on its edge: the sheet's scrollbar lives there.
	body.offset_left = _spacing
	body.offset_right = -_spacing
	button.add_child(body)

	var line := HBoxContainer.new()
	line.name = "Head"
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	line.add_theme_constant_override(&"separation", int(_spacing))
	body.add_child(line)

	var name_label := UIWidgets.label("Name",
			("%s %s" % [str(row["dept_glyph"]), str(row["name"])]).strip_edges())
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	UIWidgets.paint_state(self, name_label, row["state_token"])
	line.add_child(name_label)

	# §2.6's ETA column is "bold, mono" — the number the whole sheet is sorted by,
	# so it is the one thing here that may never be clipped.
	var eta := _fixed(UIWidgets.label("Eta", eta_text))
	eta.theme_type_variation = &"StatChip"
	line.add_child(eta)

	var sub := HBoxContainer.new()
	sub.name = "Sub"
	sub.mouse_filter = Control.MOUSE_FILTER_IGNORE
	sub.add_theme_constant_override(&"separation", int(_spacing))
	body.add_child(sub)
	var status := UIWidgets.label("Status", str(row["state_text"]), &"LegendRow")
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sub.add_child(status)
	var tag := _fixed(UIWidgets.label("Tag", str(row["tag_text"]), &"LegendRow"))
	UIWidgets.paint_state(self, tag, row["state_token"])
	sub.add_child(tag)
	return button


## Pins a value column to its own width so a flexible sibling cannot claim it.
static func _fixed(label: Label) -> Label:
	label.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	return label


# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

func _on_row_pressed(unit_id: int) -> void:
	var incident_id := model.incident_id()
	if incident_id <= 0:
		return
	dispatch_requested.emit(unit_id, incident_id)


## §2.6 step 2's primary button: the top-ranked eligible unit.
func dispatch_auto() -> void:
	var pick := model.auto_pick()
	if pick.is_empty():
		return
	_on_row_pressed(int(pick["id"]))


## The shell's answer to a `dispatch_requested`. `ok` closes the sheet (§2.6
## step 4) and returns the toast copy; a refusal keeps it open and says so, which
## is the only way the player can pick something else without a second ASSIGN.
func report_result(unit_id: int, ok: bool) -> String:
	if ok:
		var text := model.dispatched_text(unit_id)
		close()
		return text
	if _message != null:
		_message.text = UIWidgets.t(config, "ui_picker_failed")
		_message.visible = true
	return UIWidgets.t(config, "ui_picker_failed")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func auto_button() -> Button:
	return _auto


func unit_button(unit_id: int) -> Button:
	return _rows.get(unit_id, null)


func incident_id() -> int:
	return model.incident_id() if model != null else 0


func message_text() -> String:
	return _message.text if _message != null else ""
