class_name SettingsSheet
extends Control
## S9 (doc 12 §2.2, §2.13) at Phase-1 scope: graphics preset, autosave interval,
## sound level, the two accessibility switches, in-app banners, text size, the
## About block and the door to the save slots.
##
## A full-screen modal on `ModalLayer`, so its scrim is the only `STOP` control
## in the stack while it is up and Android BACK closes it first (§2.2).
##
## Every row is one 48 dp target that **cycles** its value — a choice row walks
## its options and wraps, a toggle flips, a slider steps. No dropdowns, no
## drag-only sliders: on a phone the cheapest correct control is a big button
## that says what it is now. `SettingsModel` owns the options, the validation and
## the display strings; this file owns none of them.

signal settings_changed(key: StringName, value: Variant)
signal saves_requested
signal sheet_toggled(open: bool)

const SCRIM_ALPHA := 0.55  ## §2.17's dim, reused for every modal scrim

var config: UIConfig
var model: SettingsModel

var _scrim: ColorRect
var _panel: PanelContainer
var _title: Label
var _close: Button
var _rows_box: VBoxContainer
var _about_box: VBoxContainer
var _saves_button: Button

var _row_buttons: Dictionary = {}   # key -> Button
var _touch_min := 48.0
var _spacing := 8.0


func setup(cfg: UIConfig = null, p_model: SettingsModel = null) -> void:
	if cfg != null:
		config = cfg
	if config == null:
		config = UIConfig.load_from_files()
	model = p_model if p_model != null else SettingsModel.new(config)
	var defaults := config.section("defaults")
	_touch_min = float(ThemeBuilder.touch_min_dp(config,
			UIConfig.get_num(defaults, "text_scale", 1.0),
			bool(defaults.get("larger_touch_targets", false))))
	_spacing = UIConfig.get_num(config.layout(), "touch_spacing_min_dp", 8.0)
	_bind_nodes()
	_build_static()
	_build_rows()
	_build_about()
	close()


func _ready() -> void:
	if model == null:
		setup(UIRoot.config_from(self))


func _bind_nodes() -> void:
	_scrim = get_node_or_null("Scrim") as ColorRect
	_panel = get_node_or_null("Panel") as PanelContainer
	_title = get_node_or_null("Panel/Body/Header/Title") as Label
	_close = get_node_or_null("Panel/Body/Header/Close") as Button
	_rows_box = get_node_or_null("Panel/Body/Scroll/Rows") as VBoxContainer
	_about_box = get_node_or_null("Panel/Body/About") as VBoxContainer
	_saves_button = get_node_or_null("Panel/Body/Saves") as Button


func _build_static() -> void:
	if _scrim != null:
		_scrim.color = UIWidgets.scrim_color(self, SCRIM_ALPHA)
	if _title != null:
		_title.text = UIWidgets.t(config, "ui_settings_title")
		# Authored with `clip_text` in the scene, which reports a one-pixel minimum
		# and lets the ✕ beside it claim the whole header row.
		UIWidgets.elide(_title, _touch_min * 2.0)
	if _close != null:
		_close.theme_type_variation = &"GhostButton"
		_close.focus_mode = Control.FOCUS_NONE
		_close.custom_minimum_size = Vector2(_touch_min, _touch_min)
		_close.text = "✕"
		_close.tooltip_text = UIWidgets.t(config, "ui_settings_close")
		if not _close.pressed.is_connected(close):
			_close.pressed.connect(close)
	if _saves_button != null:
		_saves_button.theme_type_variation = &"PrimaryFAB"
		_saves_button.focus_mode = Control.FOCUS_NONE
		_saves_button.custom_minimum_size = Vector2(_touch_min * 3.0, _touch_min)
		_saves_button.text = UIWidgets.t(config, "ui_settings_open_saves")
		_saves_button.tooltip_text = _saves_button.text
		if not _saves_button.pressed.is_connected(_on_saves_pressed):
			_saves_button.pressed.connect(_on_saves_pressed)
	if _rows_box != null:
		_rows_box.add_theme_constant_override(&"separation", int(_spacing))


func _build_rows() -> void:
	if _rows_box == null:
		return
	UIWidgets.clear_children(_rows_box)
	_row_buttons.clear()
	for row: Dictionary in model.rows():
		_rows_box.add_child(_build_row(row))
	_refresh_values()


## One 48 dp target per row: name on the left, current value on the right. A row
## that also has something to explain gets a second **line**, not a third column
## — the sound row's note was wedged between the two and wrapped to four lines,
## which made one row three times the height of its neighbours and read as a
## layout fault rather than as a note.
##
## **The line is an `HFlowContainer`, not an `HBox` (D-47).** An `HBox` asks for
## the sum of its children, so `Emergency contractors` (201 dp) beside its value
## chip (183 dp) made the row 392 dp; the row list made the scroller that wide,
## the scroller made the sheet that wide, and a `grow_horizontal = BOTH` panel
## then centred 420 dp of sheet on a 360 dp phone and put its own ✕ 20 dp off the
## right edge. A flow container asks for its WIDEST CHILD and drops the value
## onto a second line when the two do not fit, so the row costs 201 dp and the
## reference box is unchanged — at 880 dp both still sit on one line, with the
## label expanding and the value flush right exactly as before.
func _build_row(row: Dictionary) -> Container:
	var key := str(row["key"])
	var line := HFlowContainer.new()
	line.name = "Row_" + key
	line.add_theme_constant_override(&"h_separation", int(_spacing))
	line.add_theme_constant_override(&"v_separation", int(_spacing))

	var label := UIWidgets.label("Label", UIWidgets.t(config, str(row["label_key"])))
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	line.add_child(label)

	var value := UIWidgets.button("Value_" + key, str(row["value_text"]),
			"%s: %s" % [label.text, str(row["value_text"])],
			Vector2(maxf(_touch_min * 2.5, 120.0), _touch_min), &"StatChip")
	value.pressed.connect(_on_row_pressed.bind(key))
	line.add_child(value)
	_row_buttons[key] = value

	# A row whose effect is not obvious from its own name says so on a second
	# line rather than shipping a control the player has to guess at (A14). The
	# key is the row's, in `data/ui.json` — the sound row's caveat and the
	# auto-response rows' one-sentence explanations are the same mechanism, and
	# neither is a branch in this file.
	var hint_key := str(row.get("hint_key", ""))
	if hint_key == "":
		return line
	var stack := VBoxContainer.new()
	stack.name = "Row_" + key
	line.name = "Line"
	stack.add_theme_constant_override(&"separation", 0)
	stack.add_child(line)
	var hint := UIWidgets.label("Hint", UIWidgets.t(config, hint_key), &"LegendRow", true)
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	stack.add_child(hint)
	return stack


func _build_about() -> void:
	if _about_box == null:
		return
	UIWidgets.clear_children(_about_box)
	_about_box.add_child(UIWidgets.label("Title",
			UIWidgets.t(config, "ui_settings_about_title"), &"LegendRow"))
	for row: Dictionary in model.about_rows():
		_about_box.add_child(UIWidgets.label("About_" + str(row["label_key"]),
				str(row["text"])))


# ---------------------------------------------------------------------------
# Values
# ---------------------------------------------------------------------------

func _on_row_pressed(key: String) -> void:
	match model.kind(key):
		SettingsModel.KIND_TOGGLE:
			model.toggle(key)
		SettingsModel.KIND_SLIDER:
			model.step_slider(key, 1)
		_:
			model.cycle(key)
	_refresh_values()
	settings_changed.emit(StringName(key), model.value(key))


func _refresh_values() -> void:
	for row: Dictionary in model.rows():
		var key := str(row["key"])
		var button: Button = _row_buttons.get(key, null)
		if button == null:
			continue
		button.text = str(row["value_text"])
		button.tooltip_text = "%s: %s" % [
				UIWidgets.t(config, str(row["label_key"])), str(row["value_text"])]


## Re-reads every row's value from the model. Public because §2.13's
## auto-response rows are seeded from the *sim* rather than from a tap
## (`UIRoot.bind_dispatch_policy`), and a seeded row that still shows its old
## face is a settings screen that lies about the city it is attached to.
func refresh_values() -> void:
	_refresh_values()


## Applies a whole settings block (a loaded save, or `user://settings.cfg`) and
## re-renders. Returns the keys the model dropped, per §3.2's migration policy.
func apply_state(state: Dictionary) -> PackedStringArray:
	var dropped := model.restore_state(state)
	_refresh_values()
	return dropped


func capture_state() -> Dictionary:
	return model.capture_state() if model != null else {}


# ---------------------------------------------------------------------------
# Open / close
# ---------------------------------------------------------------------------

func is_open() -> bool:
	return _panel != null and _panel.visible


func open() -> void:
	UIWidgets.close_siblings(self)
	_refresh_values()
	_build_about()
	_set_visible(true)
	sheet_toggled.emit(true)


func close() -> void:
	_set_visible(false)
	sheet_toggled.emit(false)


func toggle() -> void:
	if is_open():
		close()
	else:
		open()


func _set_visible(value: bool) -> void:
	if _panel != null:
		_panel.visible = value
	if _scrim != null:
		# The scrim is the modal: it is the only STOP control while the sheet is
		# up, and it stops existing the moment the sheet closes (§4.1).
		_scrim.visible = value
		_scrim.mouse_filter = Control.MOUSE_FILTER_STOP if value \
				else Control.MOUSE_FILTER_IGNORE


func _on_saves_pressed() -> void:
	saves_requested.emit()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func value_button(key: String) -> Button:
	return _row_buttons.get(key, null)
